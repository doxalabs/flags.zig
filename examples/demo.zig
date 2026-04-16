const std = @import("std");
const flags = @import("flags");

const CLI = struct {
    verbose: bool = false,
    config: ?[]const u8 = null,
    command: union(enum) {
        serve: struct {
            host: []const u8 = "localhost",
            port: u16 = 8080,
        },
        greet: struct {
            name: []const u8 = "world",
            times: u8 = 1,
        },

        pub const help =
            \\Usage: serve  <flags>
            \\
            \\Commands:
            \\  serve        Start a server
            \\      --host   Hostname to bind (default: localhost)
            \\      --port   Port to listen on (default: 8080)
            \\  greet        Print a greeting
            \\      --name   Name to greet (default: world)
            \\      --times  Number of times to greet (default: 1)
        ;
    },

    pub const help =
        \\Usage: demo [options] <command> [command-options]
        \\
        \\Options:
        \\  --verbose    Enable verbose output (default: false)
        \\  --config     Path to config file (optional)
        \\
        \\Run `demo <command> --help` to see command-specific options.
    ;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const cli = flags.parse(allocator, args, CLI) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer flags.deinit(allocator, cli);

    if (cli.verbose) {
        std.debug.print("[verbose] config={s}\n", .{cli.config orelse "(none)"});
    }

    switch (cli.command) {
        .serve => |s| {
            std.debug.print("Starting server on {s}:{d}\n", .{ s.host, s.port });
        },
        .greet => |g| {
            for (0..g.times) |_| {
                std.debug.print("Hello, {s}!\n", .{g.name});
            }
        },
    }
}
