# Code Review — flags.zig

**Date:** 2026-02-23  
**Zig version:** 0.15.2

---

## Summary

**12 issues found** — 2 critical, 2 high, 4 medium, 4 low.

Issues are split into **Bugs** (broken behavior) and **Cleanup** (code quality / test hygiene).

---

## Bugs

### #1 — CRITICAL · `print_help` produces no output

**Location:** `src/flags.zig:364-376`

`print_help` creates a `std.fs.File.Writer` with a stack buffer and uses its `.interface` (`std.Io.Writer`) to write. The `.interface` buffers data and drains to the underlying file descriptor when the buffer fills, but **any remaining bytes in the buffer are never flushed**. The `File.Writer` that owns the flush/drain logic goes out of scope without flushing. Running `--help` or `-h` exits cleanly but prints nothing (unless help text happens to exceed 1024 bytes, in which case only full buffer-sized chunks appear).

**Reproduction:**
```sh
zig build example -- --help     # exits 0, prints nothing
zig build example -- serve -h   # exits 0, prints nothing
```

**Fix:** Call `.flush()` on the `std.fs.File.Writer` (not the `.interface`) before returning:
```zig
fn print_help(comptime T: type) error{HelpRequested} {
    var buffer: [1024]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buffer);

    if (@hasDecl(T, "help")) {
        bw.interface.writeAll(T.help) catch {};
        bw.interface.writeAll("\n") catch {};
    } else {
        bw.interface.writeAll("No help available. Declare `pub const help` on your type.\n") catch {};
    }
    bw.interface.flush() catch {};

    return error.HelpRequested;
}
```

---

### #2 — CRITICAL · Memory leak on multi-slice error path

**Location:** `src/flags.zig:193-219`

When multiple slice fields exist and building a later slice fails (e.g. a parse error in the second slice), already-built slices are leaked. The `errdefer` at L193 checks `slice_assigned[fi]`, but when a later allocation or parse fails, previously assigned slices aren't freed.

**Status:** Partially fixed (the `slice_assigned` array was added), but verify with the test at L1160.

---

### #3 — HIGH · `positional_only = true` after first positional prevents flag interleaving

**Location:** `src/flags.zig:190`

After consuming the first positional argument, `positional_only` is set to `true`. This causes all subsequent arguments — including `--flags` — to be treated as positional values.

**Reproduction:**
```zig
const Args = struct {
    verbose: bool = false,
    @"--": void,
    input: []const u8,
};
// This returns TooManyPositionals, not the expected parsed result:
flags.parse(allocator, &.{ "prog", "main.zig", "--verbose" }, Args);
```

**Fix:** Remove `positional_only = true;` on L190, or make it opt-in. Most CLI tools allow `cmd file.txt --verbose`.

---

### #4 — HIGH · Subcommand field blocks positional arguments

**Location:** `src/flags.zig:165-176`

If a struct defines both a subcommand union and positional fields (via `@"--"`), any non-flag argument is unconditionally routed to `parse_commands`. A non-matching argument returns `UnknownSubcommand` instead of falling through to positional handling.

**Fix:** Check whether `arg` matches a valid subcommand name before calling `parse_commands`, or add a compile-time error forbidding the combination.

---

## Cleanup

### #5 — MEDIUM · 44 tests use `expect(x == y)` instead of `expectEqual`

**Location:** Throughout test section (~L382–L1189)

Tests use `try std.testing.expect(result.port == 3000)` instead of `try std.testing.expectEqual(@as(u16, 3000), result.port)`. When `expect` fails, you only see "expected true, found false". `expectEqual` prints the actual values.

**Fix:** Replace all `expect(x == y)` with `expectEqual(expected, actual)`.

---

### #6 — MEDIUM · 31 tests use `expect(std.mem.eql(...))` instead of `expectEqualStrings`

**Location:** Throughout test section

Tests use `try std.testing.expect(std.mem.eql(u8, result.name, "test"))` instead of `try std.testing.expectEqualStrings("test", result.name)`. The latter prints a diff of the strings on failure.

**Fix:** Replace all `expect(std.mem.eql(u8, a, b))` with `expectEqualStrings(expected, actual)`.

---

### #7 — MEDIUM · Test "help declaration exists" doesn't test library code

**Location:** `src/flags.zig:665-673`

This test defines a struct with `pub const help` and asserts `@hasDecl` returns true. It tests Zig's `@hasDecl` builtin, not any library function. No library code (`parse`, `print_help`, `deinit`) is called.

**Fix:** Remove the test.

---

### #8 — MEDIUM · Test "invalid flag" has misleading name

**Location:** `src/flags.zig:400-406`

The test passes `"name=jack"` (no `--` prefix) and expects `UnexpectedArgument`. The name suggests a malformed flag, but it's really testing that bare arguments are rejected when no positionals are defined.

**Fix:** Rename to `"bare argument rejected without positionals"` or similar.

---

### #9 — LOW · Redundant comptime check in `parse_struct`

**Location:** `src/flags.zig:75-77`

`parse_struct` checks `@typeInfo(T) != .@"struct"` at comptime, but it's only ever called from `parse` (L14) and `parse_subcommand` (L290), both of which already guarantee `T` is a struct.

**Fix:** Remove the check.

---

### #10 — LOW · Unnecessary `try` in `parse_value` return

**Location:** `src/flags.zig:250`

`return try parse_scalar(...)` — the `try` is redundant in a return statement of a function that returns the same error union.

**Fix:** Change to `return parse_scalar(@typeInfo(T).optional.child, value);`

---

### #11 — LOW · Test "positional with default" is redundant

**Location:** `src/flags.zig:1035-1046`

This test is a subset of "positional basic" (L961), which already verifies that a positional is parsed while `output` retains its default value.

**Fix:** Remove the test or merge unique aspects into "positional basic".

---

### #12 — LOW · Demo uses `std.debug.print` (stderr) for user-facing output

**Location:** `examples/demo.zig:55,60,64`

`std.debug.print` writes to stderr and is meant for debug output. A CLI tool's normal output should go to stdout.

**Fix:** Use a `std.fs.File.stdout().writer(&buffer).interface` and call `.print(...)` / `.flush()` on it.

---

## Summary Table

| #  | Severity | Category | Location | One-liner |
|----|----------|----------|----------|-----------|
| 1  | CRITICAL | bug | flags.zig:364-376 | `print_help` never flushes — `--help` prints nothing |
| 2  | CRITICAL | bug | flags.zig:193-219 | Multi-slice error path leaks memory |
| 3  | HIGH | bug | flags.zig:190 | `positional_only` blocks flags after first positional |
| 4  | HIGH | bug | flags.zig:165-176 | Subcommand field blocks positional arg handling |
| 5  | MEDIUM | cleanup | tests | 44× `expect(x == y)` → `expectEqual` |
| 6  | MEDIUM | cleanup | tests | 31× `expect(std.mem.eql(...))` → `expectEqualStrings` |
| 7  | MEDIUM | cleanup | flags.zig:665-673 | Test "help declaration exists" tests Zig, not library |
| 8  | MEDIUM | cleanup | flags.zig:400-406 | Test name "invalid flag" is misleading |
| 9  | LOW | cleanup | flags.zig:75-77 | Redundant comptime struct check |
| 10 | LOW | cleanup | flags.zig:250 | Unnecessary `try` in return |
| 11 | LOW | cleanup | flags.zig:1035-1046 | Redundant test overlaps with "positional basic" |
| 12 | LOW | cleanup | demo.zig:55,60,64 | `debug.print` → stdout for CLI output |
