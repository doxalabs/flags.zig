/// Comptime-first CLI parser with typed flags, positional args, subcommands, and slices.
const std = @import("std");

/// Parse args into a struct (single command) or union(enum) (subcommands).
///
/// Caller passes full argv; the parser skips argv[0] (the program name).
///
/// Allocator is used for slice field allocation; caller owns returned memory.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, comptime T: type) !T {
    if (args.len == 0) return error.EmptyArgs;
    const trimmed = args[1..];
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => return parse_struct(allocator, trimmed, T),
        .@"union" => {
            if (info.@"union".tag_type == null) {
                @compileError("Args must be a union(enum) to use subcommands");
            }
            return parse_commands(allocator, trimmed, T);
        },
        else => @compileError("Args must be a struct or union(enum)"),
    }
}

/// Free all memory allocated by `parse` for the given result.
///
/// Recursively frees slice fields in structs and the active union variant.
/// Usage: `defer flags.deinit(allocator, result);`
pub fn deinit(allocator: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (std.meta.fields(T)) |field| {
                if (comptime is_slice_type(field.type)) {
                    allocator.free(@field(value, field.name));
                } else {
                    deinit(allocator, @field(value, field.name));
                }
            }
        },
        .@"union" => |u| {
            if (u.tag_type != null) {
                switch (value) {
                    inline else => |v| deinit(allocator, v),
                }
            }
        },
        .optional => if (value) |v| deinit(allocator, v),
        else => {},
    }
}

/// Apply default value or null for optional fields, otherwise return the given error.
fn apply_default(comptime field: std.builtin.Type.StructField, result: anytype, comptime error_type: anyerror) !void {
    if (field.defaultValue()) |default| {
        @field(result, field.name) = default;
    } else if (comptime @typeInfo(field.type) == .optional) {
        @field(result, field.name) = @as(field.type, null);
    } else {
        return error_type;
    }
}

/// Find the index of the '@"--"' field that separates flags from positionals.
fn separator_index(comptime fields: []const std.builtin.Type.StructField) ?usize {
    inline for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "--")) return index;
    }
    return null;
}

/// Parse a struct schema of named flags and optional positional args.
fn parse_struct(allocator: std.mem.Allocator, args: []const []const u8, comptime T: type) !T {
    const fields = std.meta.fields(T);
    const marker_idx = comptime separator_index(fields);
    const named_fields = if (marker_idx) |idx| fields[0..idx] else fields;
    const positional_fields = if (marker_idx) |idx| fields[idx + 1 ..] else &[_]std.builtin.Type.StructField{};

    if (marker_idx) |idx| {
        if (fields[idx].type != void) {
            @compileError("'@" ++ "--" ++ "' marker must be declared as void");
        }
    }

    const subcmd_idx = comptime subcommand_field_index(named_fields);
    if (comptime subcmd_idx != null and positional_fields.len > 0) {
        @compileError("subcommands and positional arguments cannot coexist in the same struct");
    }

    var result: T = undefined;
    var seen = std.mem.zeroes([named_fields.len]bool);
    var slice_assigned = std.mem.zeroes([named_fields.len]bool);
    var positional_index: usize = 0;
    var positional_only = false;

    // Initialize accumulators for slice fields.
    var slice_lists = std.mem.zeroes([named_fields.len]std.ArrayList([]const u8));
    inline for (named_fields, 0..) |field, fi| {
        if (comptime is_slice_type(field.type)) {
            slice_lists[fi] = .{};
        }
    }
    defer {
        inline for (named_fields, 0..) |field, fi| {
            if (comptime is_slice_type(field.type)) {
                slice_lists[fi].deinit(allocator);
            }
        }
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (is_help_arg(arg)) print_help(T);

        if (std.mem.eql(u8, arg, "--")) {
            if (positional_fields.len == 0) return error.UnexpectedArgument;

            positional_only = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--") and !positional_only) {
            const trimmed = arg[2..];
            var flag_name = trimmed;
            var flag_value: ?[]const u8 = null;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |pos| {
                flag_name = trimmed[0..pos];
                flag_value = trimmed[pos + 1 ..];
            }

            var found = false;
            inline for (named_fields, 0..) |field, field_index| {
                if (comptime is_union_subcommand(field)) continue;
                if (std.mem.eql(u8, flag_name, field.name)) {
                    found = true;

                    if (comptime is_slice_type(field.type)) {
                        const fv = flag_value orelse return error.MissingValue;
                        // --files=a.txt,b.txt or --files=a.txt
                        var iter = std.mem.splitScalar(u8, fv, ',');
                        while (iter.next()) |part| {
                            try slice_lists[field_index].append(allocator, part);
                        }
                        seen[field_index] = true;
                    } else {
                        if (seen[field_index]) return error.DuplicateFlag;

                        seen[field_index] = true;
                        @field(result, field.name) = try parse_value(field.type, flag_value);
                    }
                    break;
                }
            }

            if (!found) return error.UnknownFlag;
            continue;
        }

        if (!positional_only and std.mem.startsWith(u8, arg, "-")) return error.UnexpectedArgument;

        if (comptime subcmd_idx) |si| {
            const subcmd_field = named_fields[si];
            const SubT = unwrap_optional(subcmd_field.type);
            seen[si] = true;
            const parsed = try parse_commands(allocator, args[i..], SubT);
            if (comptime @typeInfo(subcmd_field.type) == .optional) {
                @field(result, subcmd_field.name) = @as(subcmd_field.type, parsed);
            } else {
                @field(result, subcmd_field.name) = parsed;
            }
            break;
        }

        if (positional_fields.len == 0) {
            return error.UnexpectedArgument;
        }

        if (positional_index >= positional_fields.len) return error.TooManyPositionals;

        inline for (positional_fields, 0..) |field, pi| {
            if (pi == positional_index) {
                @field(result, field.name) = try parse_value(field.type, arg);
            }
        }
        positional_index += 1;
        positional_only = true;
    }

    errdefer {
        inline for (named_fields, 0..) |field, fi| {
            if (comptime is_slice_type(field.type)) {
                if (slice_assigned[fi]) {
                    allocator.free(@field(result, field.name));
                }
            }
        }
    }

    // Build slices and apply defaults.
    inline for (named_fields, 0..) |field, field_index| {
        if (comptime is_union_subcommand(field)) {
            if (!seen[field_index]) {
                try apply_default(field, &result, error.MissingSubcommand);
            }
        } else if (comptime is_slice_type(field.type)) {
            if (seen[field_index]) {
                const items = slice_lists[field_index].items;
                const child = comptime @typeInfo(field.type).pointer.child;
                const typed = try allocator.alloc(child, items.len);
                errdefer allocator.free(typed);
                for (items, 0..) |raw, j| {
                    typed[j] = try parse_scalar(child, raw);
                }
                @field(result, field.name) = typed;
                slice_assigned[field_index] = true;
            } else {
                const child = comptime @typeInfo(field.type).pointer.child;
                if (field.defaultValue()) |default| {
                    const default_slice: field.type = default;
                    @field(result, field.name) = try allocator.dupe(child, default_slice);
                } else {
                    return error.MissingRequiredFlag;
                }
            }
        } else {
            if (!seen[field_index]) {
                try apply_default(field, &result, error.MissingRequiredFlag);
            }
        }
    }

    // Apply defaults for missing positional args.
    inline for (positional_fields, 0..) |field, pi| {
        if (pi >= positional_index) {
            try apply_default(field, &result, error.MissingRequiredPositional);
        }
    }

    return result;
}

/// Unwrap optional types before parsing the inner scalar value.
fn parse_value(comptime T: type, value: ?[]const u8) !T {
    if (@typeInfo(T) == .optional) {
        return try parse_scalar(@typeInfo(T).optional.child, value);
    }
    return parse_scalar(T, value);
}

/// Parse a scalar type: bool, int, float, enum, or string.
fn parse_scalar(comptime T: type, value: ?[]const u8) !T {
    if (T == bool) {
        if (value == null) return true;
        return parse_bool(value.?);
    }

    const v = value orelse return error.MissingValue;

    if (T == []const u8) return v;
    if (T == []u8) @compileError("use []const u8 for flag values");

    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, v, 0) catch return error.InvalidValue,
        .float => return std.fmt.parseFloat(T, v) catch return error.InvalidValue,
        .@"enum" => return std.meta.stringToEnum(T, v) orelse error.InvalidValue,
        else => @compileError("Unsupported flag type: " ++ @typeName(T)),
    }
}

/// Parse a boolean string value; accepts "true" or "false" only.
fn parse_bool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

/// Parse a subcommand field as either a struct or nested union(enum).
fn parse_subcommand(
    allocator: std.mem.Allocator,
    comptime field: std.builtin.Type.UnionField,
    args: []const []const u8,
) !field.type {
    const subcommand_info = @typeInfo(field.type);
    return switch (subcommand_info) {
        .@"struct" => try parse_struct(allocator, args, field.type),
        .@"union" => blk: {
            if (subcommand_info.@"union".tag_type == null) {
                @compileError("subcommand types must be struct or union(enum)");
            }
            break :blk try parse_commands(allocator, args, field.type);
        },
        .void => if (args.len > 0) error.UnexpectedArgument else {},
        else => @compileError("subcommand types must be struct, union(enum), or void"),
    };
}

/// Match and parse the first arg as a subcommand name, then parse the rest.
fn parse_commands(allocator: std.mem.Allocator, args: []const []const u8, comptime T: type) !T {
    const fields = std.meta.fields(T);

    if (args.len == 0) return error.MissingSubcommand;

    const arg = args[0];
    if (is_help_arg(arg)) print_help(T);

    inline for (fields) |field| {
        if (std.mem.eql(u8, arg, field.name)) {
            const parsed = try parse_subcommand(allocator, field, args[1..]);
            return @unionInit(T, field.name, parsed);
        }
    }

    return error.UnknownSubcommand;
}

/// Return true if the type is a slice type (not []const u8 which is a string).
fn is_slice_type(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.size == .slice and ptr.child != u8,
        else => false,
    };
}

/// Unwrap an optional type to its child, or return the type as-is.
fn unwrap_optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

/// Check whether a struct field is a union(enum) subcommand carrier.
fn is_union_subcommand(comptime field: std.builtin.Type.StructField) bool {
    const T = unwrap_optional(field.type);
    return switch (@typeInfo(T)) {
        .@"union" => |u| u.tag_type != null,
        else => false,
    };
}

/// Find the index of the single union(enum) subcommand field, if any.
fn subcommand_field_index(comptime fields: []const std.builtin.Type.StructField) ?usize {
    var idx: ?usize = null;
    for (fields, 0..) |field, i| {
        if (is_union_subcommand(field)) {
            if (idx != null) @compileError("only one union(enum) subcommand field is allowed");
            idx = i;
        }
    }
    return idx;
}

/// Return true if the argument is a help flag (-h or --help).
fn is_help_arg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Print help text and exit.
fn print_help(comptime T: type) void {
    if (@hasDecl(T, "help")) {
        std.debug.print("{s}\n", .{T.help});
    } else {
        std.debug.print("No help available. Declare `pub const help` on your type.\n", .{});
    }

    std.process.exit(0);
}

// =============================================================================
// Tests
// =============================================================================

test "auto help generation" {
    const Args = struct {
        name: []const u8 = "joe",
        port: u16 = 8080,
        active: bool = false,
    };

    try std.testing.expectEqual(false, @hasDecl(Args, "help"));

    const Args2 = struct {
        verbose: bool = false,
        pub const help = "Usage: myapp";
    };
    try std.testing.expectEqual(true, @hasDecl(Args2, "help"));
    try std.testing.expectEqualStrings("Usage: myapp", Args2.help);
}

test "bare argument rejected without positionals" {
    const allocator = std.testing.allocator;
    const Args = struct {
        name: []const u8 = "joe",
    };

    try std.testing.expectError(error.UnexpectedArgument, parse(allocator, &.{ "prog", "name=jack" }, Args));
}

test "parse defaults" {
    const allocator = std.testing.allocator;
    const Args = struct {
        name: []const u8 = "joe",
        active: bool = false,
        port: u16 = 5000,
        rate: f32 = 1.0,
    };

    const flags = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expectEqualStrings("joe", flags.name);
    try std.testing.expectEqual(false, flags.active);
    try std.testing.expectEqual(5000, flags.port);
    try std.testing.expectEqual(1.0, flags.rate);
}

test "parse primitives" {
    const allocator = std.testing.allocator;
    const Args = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
        rate: f32 = 1.0,
        active: bool = false,
    };

    const flags = try parse(allocator, &.{ "prog", "--name=test", "--port=9090", "--rate=2.5", "--active" }, Args);
    try std.testing.expectEqualStrings("test", flags.name);
    try std.testing.expectEqual(9090, flags.port);
    try std.testing.expectEqual(2.5, flags.rate);
    try std.testing.expectEqual(true, flags.active);
}

test "parse enum" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        format: Format = .json,
    };

    const flags = try parse(allocator, &.{ "prog", "--format=yaml" }, Args);
    try std.testing.expectEqual(Format.yaml, flags.format);
}

test "parse enum with default" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        format: Format = .json,
    };

    const flags = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expectEqual(Format.json, flags.format);
}

test "parse optional types" {
    const allocator = std.testing.allocator;
    const Args = struct {
        config: ?[]const u8 = null,
        count: ?u32 = null,
        verbose: ?bool = null,
    };

    const flags1 = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expectEqual(null, flags1.config);
    try std.testing.expectEqual(null, flags1.count);
    try std.testing.expectEqual(null, flags1.verbose);

    const flags2 = try parse(allocator, &.{ "prog", "--config=/path/to/config", "--count=42", "--verbose" }, Args);
    try std.testing.expectEqualStrings("/path/to/config", flags2.config.?);
    try std.testing.expectEqual(42, flags2.count.?);
    try std.testing.expectEqual(true, flags2.verbose.?);
}

test "parse boolean formats" {
    const allocator = std.testing.allocator;
    const Args = struct {
        flag: bool = false,
    };

    const flags1 = try parse(allocator, &.{ "prog", "--flag" }, Args);
    try std.testing.expectEqual(true, flags1.flag);

    const flags2 = try parse(allocator, &.{ "prog", "--flag=true" }, Args);
    try std.testing.expectEqual(true, flags2.flag);

    const flags3 = try parse(allocator, &.{ "prog", "--flag=false" }, Args);
    try std.testing.expectEqual(false, flags3.flag);
}

test "parse subcommand" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct {
            host: []const u8 = "localhost",
            port: u16 = 8080,
        },
        stop: struct {
            force: bool = false,
        },
    };

    const result1 = try parse(allocator, &.{ "prog", "start", "--host=0.0.0.0", "--port=3000" }, CLI);
    try std.testing.expectEqualStrings("0.0.0.0", result1.start.host);
    try std.testing.expectEqual(3000, result1.start.port);

    const result2 = try parse(allocator, &.{ "prog", "stop", "--force" }, CLI);
    try std.testing.expectEqual(true, result2.stop.force);
}

test "parse subcommand with defaults" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct {
            host: []const u8 = "localhost",
            port: u16 = 8080,
        },
        stop: struct {},
    };

    const result = try parse(allocator, &.{ "prog", "start" }, CLI);
    try std.testing.expectEqualStrings("localhost", result.start.host);
    try std.testing.expectEqual(8080, result.start.port);
}

test "void subcommand variant" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct {
            port: u16 = 8080,
        },
        stop: void,
    };

    const result = try parse(allocator, &.{ "prog", "stop" }, CLI);
    try std.testing.expectEqual(CLI.stop, result);

    const result2 = try parse(allocator, &.{ "prog", "start" }, CLI);
    try std.testing.expectEqual(8080, result2.start.port);
}

test "void subcommand variant with extra args" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct { port: u16 = 8080 },
        stop: void,
    };

    try std.testing.expectError(error.UnexpectedArgument, parse(allocator, &.{ "prog", "stop", "--force" }, CLI));
}

test "void subcommand variant rejects help arg" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct { port: u16 = 8080 },
        stop: void,
    };

    try std.testing.expectError(error.UnexpectedArgument, parse(allocator, &.{ "prog", "stop", "--help" }, CLI));
}

test "missing subcommand" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        start: struct {
            host: []const u8 = "localhost",
        },
        stop: struct {
            force: bool = false,
        },
    };

    try std.testing.expectError(error.MissingSubcommand, parse(allocator, &.{"prog"}, CLI));
}

test "unknown subcommand" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            start: struct {
                host: []const u8 = "localhost",
            },
            stop: struct {
                force: bool = false,
            },
        },
    };

    try std.testing.expectError(error.UnknownSubcommand, parse(allocator, &.{ "prog", "--verbose", "restart" }, CLI));
}

test "duplicate flag" {
    const allocator = std.testing.allocator;
    const Args = struct {
        port: u16 = 8080,
    };

    try std.testing.expectError(error.DuplicateFlag, parse(allocator, &.{ "prog", "--port=8080", "--port=9090" }, Args));
}

test "missing value" {
    const allocator = std.testing.allocator;
    const Args = struct {
        name: []const u8,
    };

    try std.testing.expectError(error.MissingValue, parse(allocator, &.{ "prog", "--name" }, Args));
}

test "invalid enum value" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        format: Format = .json,
    };

    try std.testing.expectError(error.InvalidValue, parse(allocator, &.{ "prog", "--format=xml" }, Args));
}

test "invalid int value" {
    const allocator = std.testing.allocator;
    const Args = struct {
        port: u16 = 8080,
    };

    try std.testing.expectError(error.InvalidValue, parse(allocator, &.{ "prog", "--port=not-a-number" }, Args));
}

test "no args provided" {
    const allocator = std.testing.allocator;
    const Args = struct {
        port: u16 = 8080,
    };

    try std.testing.expectError(error.EmptyArgs, parse(allocator, &.{}, Args));
}

test "missing required flag" {
    const allocator = std.testing.allocator;
    const Args = struct {
        name: []const u8,
    };

    try std.testing.expectError(error.MissingRequiredFlag, parse(allocator, &.{"prog"}, Args));
}

test "complex subcommand structure" {
    const allocator = std.testing.allocator;
    const CLI = union(enum) {
        server: union(enum) {
            start: struct {
                host: []const u8 = "0.0.0.0",
                port: u16 = 8080,
            },
            stop: struct {
                force: bool = false,
            },
            pub const help = "Server commands";
        },
        client: struct {
            url: []const u8,
            timeout: u32 = 30,
        },
    };

    const result = try parse(allocator, &.{ "prog", "server", "start", "--port=9090" }, CLI);
    try std.testing.expectEqualStrings("0.0.0.0", result.server.start.host);
    try std.testing.expectEqual(9090, result.server.start.port);
}

test "unexpected argument error" {
    const allocator = std.testing.allocator;
    const Args = struct {
        port: u16 = 8080,
    };

    try std.testing.expectError(error.UnexpectedArgument, parse(allocator, &.{ "prog", "--port=8080", "extra" }, Args));
}

// --- Slice tests ---

test "slice repeated flags" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt", "--files=b.txt", "--files=c.txt" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(3, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqualStrings("c.txt", result.files[2]);
}

test "slice comma separated" {
    const allocator = std.testing.allocator;

    const StringArgs = struct {
        files: []const []const u8 = &[_][]const u8{},
    };
    const str_result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt,c.txt" }, StringArgs);
    defer deinit(allocator, str_result);

    try std.testing.expectEqual(3, str_result.files.len);
    try std.testing.expectEqualStrings("a.txt", str_result.files[0]);
    try std.testing.expectEqualStrings("b.txt", str_result.files[1]);
    try std.testing.expectEqualStrings("c.txt", str_result.files[2]);

    const single_str_result = try parse(allocator, &.{ "prog", "--files=single.txt" }, StringArgs);
    defer deinit(allocator, single_str_result);
    try std.testing.expectEqual(1, single_str_result.files.len);
    try std.testing.expectEqualStrings("single.txt", single_str_result.files[0]);

    const IntArgs = struct {
        ports: []const u16 = &[_]u16{},
    };
    const int_result = try parse(allocator, &.{ "prog", "--ports=80,443,8080" }, IntArgs);
    defer deinit(allocator, int_result);

    try std.testing.expectEqual(3, int_result.ports.len);
    try std.testing.expectEqual(80, int_result.ports[0]);
    try std.testing.expectEqual(443, int_result.ports[1]);
    try std.testing.expectEqual(8080, int_result.ports[2]);
}

test "slice integer values" {
    const allocator = std.testing.allocator;
    const Args = struct {
        ports: []const u16 = &[_]u16{},
    };

    const result = try parse(allocator, &.{ "prog", "--ports=8080", "--ports=9090", "--ports=3000" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(3, result.ports.len);
    try std.testing.expectEqual(8080, result.ports[0]);
    try std.testing.expectEqual(9090, result.ports[1]);
    try std.testing.expectEqual(3000, result.ports[2]);
}

test "slice enum values" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        formats: []const Format = &[_]Format{},
    };

    const result = try parse(allocator, &.{ "prog", "--formats=json,yaml,toml" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(3, result.formats.len);
    try std.testing.expectEqual(Format.json, result.formats[0]);
    try std.testing.expectEqual(Format.yaml, result.formats[1]);
    try std.testing.expectEqual(Format.toml, result.formats[2]);
}

test "slice with default" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
    };

    const result = try parse(allocator, &.{"prog"}, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(0, result.files.len);
}

test "slice mixed with scalar flags" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        verbose: bool = false,
        port: u16 = 8080,
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt", "--verbose", "--files=b.txt", "--port=3000" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(3000, result.port);
}

test "slice invalid element" {
    const allocator = std.testing.allocator;
    const Args = struct {
        ports: []const u16 = &[_]u16{},
    };

    try std.testing.expectError(error.InvalidValue, parse(allocator, &.{ "prog", "--ports=80,not_a_number" }, Args));
}

test "multiple slice fields" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        ports: []const u16 = &[_]u16{},
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,443" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualStrings("a.txt", result.files[0]);
    try std.testing.expectEqualStrings("b.txt", result.files[1]);
    try std.testing.expectEqual(2, result.ports.len);
    try std.testing.expectEqual(80, result.ports[0]);
    try std.testing.expectEqual(443, result.ports[1]);
}

test "global flags with subcommand" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        config: ?[]const u8 = null,
        command: union(enum) {
            serve: struct {
                host: []const u8 = "0.0.0.0",
                port: u16 = 8080,
            },
            migrate: struct {
                dry_run: bool = false,
            },
        },
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "--config=app.toml", "serve", "--port=3000" }, CLI);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("app.toml", result.config.?);
    try std.testing.expectEqualStrings("0.0.0.0", result.command.serve.host);
    try std.testing.expectEqual(3000, result.command.serve.port);
}

test "subcommand with defaults and global flags" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            serve: struct {
                host: []const u8 = "localhost",
                port: u16 = 8080,
            },
            stop: struct {},
        },
    };

    const result = try parse(allocator, &.{ "prog", "serve" }, CLI);
    try std.testing.expectEqual(false, result.verbose);
    try std.testing.expectEqualStrings("localhost", result.command.serve.host);
    try std.testing.expectEqual(8080, result.command.serve.port);
}

test "required subcommand missing" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            serve: struct { port: u16 = 8080 },
            migrate: struct { dry_run: bool = false },
        },
    };

    try std.testing.expectError(error.MissingSubcommand, parse(allocator, &.{"prog"}, CLI));
    try std.testing.expectError(error.MissingSubcommand, parse(allocator, &.{ "prog", "--verbose" }, CLI));
}

test "optional subcommand not given" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: ?union(enum) {
            serve: struct { port: u16 = 8080 },
        } = null,
    };

    const result = try parse(allocator, &.{ "prog", "--verbose" }, CLI);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(null, result.command);
}

test "subcommand with nested union" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            server: union(enum) {
                start: struct {
                    port: u16 = 8080,
                },
                stop: struct {
                    force: bool = false,
                },
            },
        },
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "server", "start", "--port=3000" }, CLI);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(3000, result.command.server.start.port);
}

// --- Positional tests ---

test "positional basic" {
    const allocator = std.testing.allocator;
    const Args = struct {
        verbose: bool = false,
        @"--": void,
        input: []const u8,
        output: []const u8 = "out.txt",
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "main.zig" }, Args);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("main.zig", result.input);
    try std.testing.expectEqualStrings("out.txt", result.output);
}

test "positional multiple" {
    const allocator = std.testing.allocator;
    const Args = struct {
        @"--": void,
        input: []const u8,
        output: []const u8 = "out.txt",
    };

    const result = try parse(allocator, &.{ "prog", "main.zig", "build.bin" }, Args);
    try std.testing.expectEqualStrings("main.zig", result.input);
    try std.testing.expectEqualStrings("build.bin", result.output);
}

test "positional with explicit separator" {
    const allocator = std.testing.allocator;
    const Args = struct {
        verbose: bool = false,
        @"--": void,
        input: []const u8,
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "--", "main.zig" }, Args);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqualStrings("main.zig", result.input);
}

test "positional with negative and dash-prefixed values after separator" {
    const allocator = std.testing.allocator;

    const ArgsInt = struct {
        @"--": void,
        value: i32,
    };
    const result_int = try parse(allocator, &.{ "prog", "--", "-5" }, ArgsInt);
    try std.testing.expectEqual(-5, result_int.value);

    const ArgsFloat = struct {
        @"--": void,
        value: f64,
    };
    const result_float = try parse(allocator, &.{ "prog", "--", "-3.14" }, ArgsFloat);
    try std.testing.expectEqual(-3.14, result_float.value);

    const ArgsString = struct {
        @"--": void,
        name: []const u8,
    };
    const result_string = try parse(allocator, &.{ "prog", "--", "-filename" }, ArgsString);
    try std.testing.expectEqualStrings("-filename", result_string.name);
}

test "positional missing required" {
    const allocator = std.testing.allocator;
    const Args = struct {
        @"--": void,
        input: []const u8,
    };

    try std.testing.expectError(error.MissingRequiredPositional, parse(allocator, &.{"prog"}, Args));
}

test "positional too many" {
    const allocator = std.testing.allocator;
    const Args = struct {
        @"--": void,
        input: []const u8,
    };

    try std.testing.expectError(error.TooManyPositionals, parse(allocator, &.{ "prog", "a.zig", "b.zig" }, Args));
}

test "positional inside subcommand" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            compile: struct {
                optimize: bool = false,
                @"--": void,
                input: []const u8,
                output: []const u8 = "a.out",
            },
        },
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "compile", "--optimize", "main.zig" }, CLI);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(true, result.command.compile.optimize);
    try std.testing.expectEqualStrings("main.zig", result.command.compile.input);
    try std.testing.expectEqualStrings("a.out", result.command.compile.output);
}

// --- Deinit tests ---

test "deinit frees struct with slices" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        ports: []const u16 = &[_]u16{},
        verbose: bool = false,
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,443", "--verbose" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqual(2, result.ports.len);
    try std.testing.expectEqual(true, result.verbose);
}

test "deinit frees subcommand with slices" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            serve: struct {
                hosts: []const []const u8 = &[_][]const u8{},
                port: u16 = 8080,
            },
            stop: struct {},
        },
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "serve", "--hosts=a.com,b.com" }, CLI);
    defer deinit(allocator, result);

    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(2, result.command.serve.hosts.len);
}

test "deinit with defaults only" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        ports: []const u16 = &[_]u16{},
        name: []const u8 = "default",
    };

    const result = try parse(allocator, &.{"prog"}, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(0, result.files.len);
    try std.testing.expectEqual(0, result.ports.len);
}

test "deinit with optional subcommand null" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: ?union(enum) {
            serve: struct {
                hosts: []const []const u8 = &[_][]const u8{},
            },
        } = null,
    };

    const result = try parse(allocator, &.{ "prog", "--verbose" }, CLI);
    defer deinit(allocator, result);

    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(null, result.command);
}

test "multi-slice error path does not leak" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        ports: []const u16 = &[_]u16{},
    };

    // Second slice has an invalid value — first slice must not leak
    try std.testing.expectError(
        error.InvalidValue,
        parse(allocator, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,bad" }, Args),
    );
}

test "slice_lists array with non-slice and slice fields" {
    const allocator = std.testing.allocator;
    const Args = struct {
        verbose: bool = false, // non-slice at index 0
        files: []const []const u8 = &[_][]const u8{}, // slice at index 1
        name: []const u8 = "default", // slice at index 2
    };

    // This should work without undefined behavior in slice_lists array
    const result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt", "--name=test" }, Args);
    defer deinit(allocator, result);

    try std.testing.expectEqual(false, result.verbose);
    try std.testing.expectEqual(2, result.files.len);
    try std.testing.expectEqualSlices(u8, result.name, "test");
}
