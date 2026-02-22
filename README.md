# flags.zig

A type-safe command-line argument parser for Zig. Taking inspiration from **Rust clap**, and **TigerBeetle's flags** implementation, it lets you define flags using a struct or union(enum) and parses command-line arguments into it.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Advanced Features](#advanced-features)
- [Documentation](#documentation)
- [Credits](#credits)

---

## Overview

**flags.zig** provides a declarative, type-safe approach to command-line parsing by leveraging Zig's powerful comptime capabilities. Define your CLI interface as a struct with defaults and types, and let the library handle the rest.

### Why flags.zig?

- Zero runtime overhead—parsing happens at comptime where possible
- Type safety—catch errors at compile time, not runtime
- Idiomatic Zig—works with the grain of the language
- Zero external dependencies

---

## Features

- [x] Multiple flag types (bool, string, int, float, enum)
- [x] Struct-based argument definition
- [x] Default values via struct fields
- [x] Error handling for invalid/unknown flags
- [x] Positional arguments support
- [x] Subcommands via `union(enum)`
- [x] Slice support (multiple values per flag)
- [x] Two parsing patterns: repeated, comma-separated

---

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

---

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

---

## Usage Examples

### Basic Flags

```bash
./program --name=alice --age=30 --active
```

### Individual Flag Types

```bash
# String flag
./program --name=bob

# Integer flag
./program --age=40

# Boolean flag (presence = true)
./program --active
```

### Getting Help

```bash
./program --help # or -h
```

### Slice (Multiple Values) Support

```zig
const Args = struct {
    files: []const []const u8 = &[_][]const u8{},
    ports: []u16 = &[_]u16{8080},
    tags: []const []const u8 = &[_][]const u8{},
};
```

#### Two Syntax Patterns:

```bash
# Repeated flags (default)
./program --files=a.txt --files=b.txt --files=c.txt

# Comma-separated values  
./program --files=a.txt,b.txt,c.txt
```

---

## Advanced Features

### Type-Safe Arguments

Leverage Zig's type system for compile-time guarantees:

```zig
const Args = struct {
    // u16 enforces valid port range (0-65535)
    port: u16 = 8080,
    
    // Optional types for nullable values
    config: ?[]const u8 = null,
    
    // Enums for valid choices
    format: enum { json, yaml, toml } = .json,
};
```

### Help Documentation

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

Running with `-h` or `--help` displays your help text and exits.

If no help declaration is found, it prints "No help available" and exits.

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

---

## Documentation

See [docs/](docs/) for detailed documentation:

| Document | Description |
|----------|-------------|
| [docs/README.md](docs/README.md) | Usage guide and API reference |
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture and design decisions |

---

## Not Supported

- Short flags (e.g., `-v` for verbose) - only `-h` for help
- Space-separated values (`--name value` instead of `--name=value`)
- Custom types - only built-in types and enums

---

## Credits

This library draws significant inspiration from two exceptional projects:

### TigerBeetle

The design philosophy of struct-based flag definitions and zero-cost abstractions is heavily inspired by [TigerBeetle's flags implementation](https://github.com/tigerbeetle/tigerbeetle). Their approach to type-safe, performant CLI parsing in Zig demonstrates the power of leveraging Zig's comptime capabilities.

### Rust clap

The declarative API design and developer experience patterns are influenced by [Rust's clap crate](https://github.com/clap-rs/clap). Clap's ergonomic structopt-style derive patterns informed our approach to making CLI parsing intuitive while maintaining compile-time safety.

---

<div align="center">

Made with  for the Zig community

</div>
