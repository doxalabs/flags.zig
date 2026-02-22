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
    // Ensure the given type is a struct at compile time.
    comptime if (@typeInfo(T) != .@"struct") {
        @compileError("flag definitions must be a struct");
    };

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

    var result: T = undefined;
    var seen = std.mem.zeroes([named_fields.len]bool);
    var positional_index: usize = 0;
    var positional_only = false;

    // Initialize accumulators for slice fields.
    var slice_lists: [named_fields.len]std.ArrayList([]const u8) = undefined;
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

        if (std.mem.startsWith(u8, arg, "-")) return error.UnexpectedArgument;

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

        var matched = false;
        inline for (positional_fields, 0..) |field, pi| {
            if (pi == positional_index) {
                @field(result, field.name) = try parse_value(field.type, arg);
                matched = true;
            }
        }
        if (matched) {
            positional_index += 1;
            positional_only = true;
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
            } else {
                try apply_default(field, &result, error.MissingRequiredFlag);
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
        .int => return std.fmt.parseInt(T, v, 10) catch return error.InvalidValue,
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
        else => @compileError("subcommand types must be struct or union(enum)"),
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

/// Print help text and exit. Requires `pub const help` on the type.
/// Help is the user's responsibility — the parser handles parsing, not presentation.
fn print_help(comptime T: type) noreturn {
    if (@hasDecl(T, "help")) {
        std.debug.print("{s}", .{T.help});
    } else {
        std.debug.print("No help available. Declare `pub const help` on your type.\n", .{});
    }
    // BUG: libraries don't exit
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

    try std.testing.expect(@hasDecl(Args, "help") == false);
}

test "invalid flag" {
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
    try std.testing.expect(std.mem.eql(u8, flags.name, "joe"));
    try std.testing.expect(flags.active == false);
    try std.testing.expect(flags.port == 5000);
    try std.testing.expect(flags.rate == 1.0);
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
    try std.testing.expect(std.mem.eql(u8, flags.name, "test"));
    try std.testing.expect(flags.port == 9090);
    try std.testing.expect(flags.rate == 2.5);
    try std.testing.expect(flags.active == true);
}

test "parse enum" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        format: Format = .json,
    };

    const flags = try parse(allocator, &.{ "prog", "--format=yaml" }, Args);
    try std.testing.expect(flags.format == .yaml);
}

test "parse enum with default" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        format: Format = .json,
    };

    const flags = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expect(flags.format == .json);
}

test "parse optional string" {
    const allocator = std.testing.allocator;
    const Args = struct {
        config: ?[]const u8 = null,
    };

    const flags1 = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expect(flags1.config == null);

    const flags2 = try parse(allocator, &.{ "prog", "--config=/path/to/config" }, Args);
    try std.testing.expect(flags2.config != null);
    try std.testing.expect(std.mem.eql(u8, flags2.config.?, "/path/to/config"));
}

test "parse optional int" {
    const allocator = std.testing.allocator;
    const Args = struct {
        count: ?u32 = null,
    };

    const flags1 = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expect(flags1.count == null);

    const flags2 = try parse(allocator, &.{ "prog", "--count=42" }, Args);
    try std.testing.expect(flags2.count != null);
    try std.testing.expect(flags2.count.? == 42);
}

test "parse optional bool" {
    const allocator = std.testing.allocator;
    const Args = struct {
        verbose: ?bool = null,
    };

    const flags1 = try parse(allocator, &.{"prog"}, Args);
    try std.testing.expect(flags1.verbose == null);

    const flags2 = try parse(allocator, &.{ "prog", "--verbose" }, Args);
    try std.testing.expect(flags2.verbose != null);
    try std.testing.expect(flags2.verbose.? == true);
}

test "parse boolean formats" {
    const allocator = std.testing.allocator;
    const Args = struct {
        flag: bool = false,
    };

    const flags1 = try parse(allocator, &.{ "prog", "--flag" }, Args);
    try std.testing.expect(flags1.flag == true);

    const flags2 = try parse(allocator, &.{ "prog", "--flag=true" }, Args);
    try std.testing.expect(flags2.flag == true);

    const flags3 = try parse(allocator, &.{ "prog", "--flag=false" }, Args);
    try std.testing.expect(flags3.flag == false);
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
    try std.testing.expect(std.mem.eql(u8, result1.start.host, "0.0.0.0"));
    try std.testing.expect(result1.start.port == 3000);

    const result2 = try parse(allocator, &.{ "prog", "stop", "--force" }, CLI);
    try std.testing.expect(result2.stop.force == true);
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
    try std.testing.expect(std.mem.eql(u8, result.start.host, "localhost"));
    try std.testing.expect(result.start.port == 8080);
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
    const CLI = union(enum) {
        start: struct {
            host: []const u8 = "localhost",
        },
        stop: struct {
            force: bool = false,
        },
    };

    try std.testing.expectError(error.UnknownSubcommand, parse(allocator, &.{ "prog", "restart" }, CLI));
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

test "help declaration exists" {
    const Args = struct {
        verbose: bool = false,
        pub const help = "Test help message";
    };

    try std.testing.expect(@hasDecl(Args, "help"));
    try std.testing.expect(std.mem.eql(u8, Args.help, "Test help message"));
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
    try std.testing.expect(std.mem.eql(u8, result.server.start.host, "0.0.0.0"));
    try std.testing.expect(result.server.start.port == 9090);
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
    defer allocator.free(result.files);

    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expect(std.mem.eql(u8, result.files[0], "a.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[1], "b.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[2], "c.txt"));
}

test "slice comma separated" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt,c.txt" }, Args);
    defer allocator.free(result.files);

    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expect(std.mem.eql(u8, result.files[0], "a.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[1], "b.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[2], "c.txt"));
}

test "slice integer values" {
    const allocator = std.testing.allocator;
    const Args = struct {
        ports: []const u16 = &[_]u16{},
    };

    const result = try parse(allocator, &.{ "prog", "--ports=8080", "--ports=9090", "--ports=3000" }, Args);
    defer allocator.free(result.ports);

    try std.testing.expectEqual(@as(usize, 3), result.ports.len);
    try std.testing.expectEqual(@as(u16, 8080), result.ports[0]);
    try std.testing.expectEqual(@as(u16, 9090), result.ports[1]);
    try std.testing.expectEqual(@as(u16, 3000), result.ports[2]);
}

test "slice enum values" {
    const allocator = std.testing.allocator;
    const Format = enum { json, yaml, toml };
    const Args = struct {
        formats: []const Format = &[_]Format{},
    };

    const result = try parse(allocator, &.{ "prog", "--formats=json,yaml,toml" }, Args);
    defer allocator.free(result.formats);

    try std.testing.expectEqual(@as(usize, 3), result.formats.len);
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
    // Default is used (no allocation), nothing to free.
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
}

test "slice mixed with scalar flags" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        verbose: bool = false,
        port: u16 = 8080,
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt", "--verbose", "--files=b.txt", "--port=3000" }, Args);
    defer allocator.free(result.files);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expect(std.mem.eql(u8, result.files[0], "a.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[1], "b.txt"));
    try std.testing.expect(result.verbose == true);
    try std.testing.expectEqual(@as(u16, 3000), result.port);
}

test "slice comma separated integers" {
    const allocator = std.testing.allocator;
    const Args = struct {
        ports: []const u16 = &[_]u16{},
    };

    const result = try parse(allocator, &.{ "prog", "--ports=80,443,8080" }, Args);
    defer allocator.free(result.ports);

    try std.testing.expectEqual(@as(usize, 3), result.ports.len);
    try std.testing.expectEqual(@as(u16, 80), result.ports[0]);
    try std.testing.expectEqual(@as(u16, 443), result.ports[1]);
    try std.testing.expectEqual(@as(u16, 8080), result.ports[2]);
}

test "slice invalid element" {
    const allocator = std.testing.allocator;
    const Args = struct {
        ports: []const u16 = &[_]u16{},
    };

    try std.testing.expectError(error.InvalidValue, parse(allocator, &.{ "prog", "--ports=80,not_a_number" }, Args));
}

test "slice single value" {
    const allocator = std.testing.allocator;
    const Args = struct {
        tags: []const []const u8 = &[_][]const u8{},
    };

    const result = try parse(allocator, &.{ "prog", "--tags=only-one" }, Args);
    defer allocator.free(result.tags);

    try std.testing.expectEqual(@as(usize, 1), result.tags.len);
    try std.testing.expect(std.mem.eql(u8, result.tags[0], "only-one"));
}

test "multiple slice fields" {
    const allocator = std.testing.allocator;
    const Args = struct {
        files: []const []const u8 = &[_][]const u8{},
        ports: []const u16 = &[_]u16{},
    };

    const result = try parse(allocator, &.{ "prog", "--files=a.txt,b.txt", "--ports=80,443" }, Args);
    defer allocator.free(result.files);
    defer allocator.free(result.ports);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expect(std.mem.eql(u8, result.files[0], "a.txt"));
    try std.testing.expect(std.mem.eql(u8, result.files[1], "b.txt"));
    try std.testing.expectEqual(@as(usize, 2), result.ports.len);
    try std.testing.expectEqual(@as(u16, 80), result.ports[0]);
    try std.testing.expectEqual(@as(u16, 443), result.ports[1]);
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
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(std.mem.eql(u8, result.config.?, "app.toml"));
    try std.testing.expect(std.mem.eql(u8, result.command.serve.host, "0.0.0.0"));
    try std.testing.expect(result.command.serve.port == 3000);
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
    try std.testing.expect(result.verbose == false);
    try std.testing.expect(std.mem.eql(u8, result.command.serve.host, "localhost"));
    try std.testing.expect(result.command.serve.port == 8080);
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
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(result.command == null);
}

test "unknown subcommand with global flags" {
    const allocator = std.testing.allocator;
    const CLI = struct {
        verbose: bool = false,
        command: union(enum) {
            serve: struct { port: u16 = 8080 },
        },
    };

    try std.testing.expectError(error.UnknownSubcommand, parse(allocator, &.{ "prog", "deploy" }, CLI));
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
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(result.command.server.start.port == 3000);
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
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(std.mem.eql(u8, result.input, "main.zig"));
    try std.testing.expect(std.mem.eql(u8, result.output, "out.txt"));
}

test "positional multiple" {
    const allocator = std.testing.allocator;
    const Args = struct {
        @"--": void,
        input: []const u8,
        output: []const u8 = "out.txt",
    };

    const result = try parse(allocator, &.{ "prog", "main.zig", "build.bin" }, Args);
    try std.testing.expect(std.mem.eql(u8, result.input, "main.zig"));
    try std.testing.expect(std.mem.eql(u8, result.output, "build.bin"));
}

test "positional with explicit separator" {
    const allocator = std.testing.allocator;
    const Args = struct {
        verbose: bool = false,
        @"--": void,
        input: []const u8,
    };

    const result = try parse(allocator, &.{ "prog", "--verbose", "--", "main.zig" }, Args);
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(std.mem.eql(u8, result.input, "main.zig"));
}

test "positional with default" {
    const allocator = std.testing.allocator;
    const Args = struct {
        @"--": void,
        input: []const u8,
        output: []const u8 = "a.out",
    };

    const result = try parse(allocator, &.{ "prog", "main.zig" }, Args);
    try std.testing.expect(std.mem.eql(u8, result.input, "main.zig"));
    try std.testing.expect(std.mem.eql(u8, result.output, "a.out"));
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
    try std.testing.expect(result.verbose == true);
    try std.testing.expect(result.command.compile.optimize == true);
    try std.testing.expect(std.mem.eql(u8, result.command.compile.input, "main.zig"));
    try std.testing.expect(std.mem.eql(u8, result.command.compile.output, "a.out"));
}
