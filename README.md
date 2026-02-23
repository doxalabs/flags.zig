# flags.zig

A type-safe command-line argument parser for Zig. Taking inspiration from **Rust clap**, and **TigerBeetle's flags** implementation, it lets you define flags using a struct or union(enum) and parses command-line arguments into it.

- Zero runtime overhead — parsing happens at comptime where possible
- Type safety — catch errors at compile time, not runtime
- Idiomatic Zig — works with the grain of the language
- Zero external dependencies

## Features

- [x] Multiple flag types (bool, string, int, float, enum)
- [x] Struct-based argument definition
- [x] Default values via struct fields
- [x] Error handling for invalid/unknown flags
- [x] Positional arguments support
- [x] Subcommands via `union(enum)`
- [x] Slice support (multiple values per flag)
- [x] Two parsing patterns: repeated, comma-separated

## Installation

### 1. Fetch the library

```bash
zig fetch --save git+https://github.com/atisans/flags.zig
```

### 2. Add to your `build.zig`

```zig
const flags = b.dependency("flags", .{});
exe.root_module.addImport("flags", flags.module("flags"));
```

## Quick Start

```zig
const std = @import("std");
const flags = @import("flags");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define flags as a struct with slice support
    const Args = struct {
        name: []const u8 = "world",
        age: u32 = 25,
        active: bool = false,
        
        // Multiple values supported
        files: []const []const u8 = &[_][]const u8{},
        ports: []u16 = &[_]u16{8080},
    };

    // Parse and use
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = try flags.parse(allocator, args, Args);

    std.debug.print("Hello {s}! Age: {d}, Active: {}\n", .{
        parsed.name, parsed.age, parsed.active
    });
}
```

```bash
./program --name=alice --age=30 --active

# Slices accept repeated flags or comma-separated values
./program --files=a.txt --files=b.txt --files=c.txt
./program --files=a.txt,b.txt,c.txt
```

## Advanced Features

### Help Documentation

Running with `-h` or `--help` prints your help text.

If no help declaration is found, it prints "No help available" with a hint to declare one.

Help text is defined by declaring `pub const help` on your struct or union type:

```zig
const Args = struct {
    verbose: bool = false,
    port: u16 = 8080,
    
    pub const help = 
        \\Options:
        \\  --verbose    Enable verbose output (default: false)
        \\  --port       Port to listen on (default: 8080)
    ;
};
```

### Subcommands

Git-style subcommands using `union(enum)`:

```zig
const CLI = union(enum) {
    start: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    },
    stop: struct {
        force: bool = false,
    },
    
    pub const help = 
        \\ Server management CLI
        \\ commands:
        \\  start       Start the server
        \\      --host     Hostname to bind to (default: localhost)
        \\      --port     Port to listen on (default: 8080)
        \\  stop        Stop the server
        \\      --force    Force stop (default: false)
    ;
};

const cli = try flags.parse(allocator, args, CLI);
switch (cli) {
    .start => |s| startServer(s.host, s.port),
    .stop => |s| stopServer(s.force),
}
```

### Global Flags with Subcommands

Combine top-level flags with subcommands using a struct that contains a `union(enum)`:

```zig
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

const cli = try flags.parse(allocator, args, CLI);
if (cli.verbose) std.debug.print("verbose mode\n", .{});
switch (cli.command) {
    .serve => |s| startServer(s.host, s.port),
    .migrate => |m| runMigration(m.dry_run),
}
```

```bash
prog --verbose serve --port=3000
prog --config=app.toml migrate --dry_run
```

### Positional Arguments

Use the `@"--"` marker to separate flags from positional arguments:

```zig
const Args = struct {
    verbose: bool = false,
    @"--": void,
    input: []const u8,
    output: []const u8 = "output.txt",
};

// Usage: program --verbose input.txt output.txt
```

See [docs/](docs/) for the full API reference and design details.

## Not Supported

- Short flags (e.g., `-v` for verbose) - only `-h` for help
- Space-separated values (`--name value` instead of `--name=value`)
- Custom types - only built-in types and enums

## Credits
This library draws significant inspiration from two exceptional projects:

- [TigerBeetle's flags](https://github.com/tigerbeetle/tigerbeetle) — struct-based flag definitions and zero-cost abstractions
- [Rust clap](https://github.com/clap-rs/clap) — declarative API design and derive-style patterns
