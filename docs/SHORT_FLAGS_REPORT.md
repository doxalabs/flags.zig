# Short Flags Report: Remove, Keep, or Redesign?

**Date**: 2026-02-22  
**Verdict**: **Remove the current implementation. It is a net negative.**

---

## What the Current Implementation Actually Does

The short flag handler (lines 158–175 of `src/flags.zig`) does this:

1. Checks if the arg starts with `-` and has exactly 2 characters (e.g., `-v`)
2. Matches the second character against single-character struct field names
3. Calls `parse_value(field.type, null)` — always passes `null` as the value

That's it. No value extraction, no combining, no aliasing.

---

## Seven Confirmed Footguns

Every issue below was confirmed by a passing test against the current code.

### 1. Non-bool short flags are a trap

```zig
const Args = struct { p: u16 = 8080 };
// -p → parse_value(u16, null) → MissingValue error
// The field compiles fine but can never be set via short flag
```

**Problem**: Users can declare `p: u16` and it compiles, but `-p` always returns `MissingValue` because `null` is passed as the value. There's no `-p=3000` or `-p 3000` path. The field works only via `--p=3000`, defeating the purpose of a short flag.

### 2. `-p=value` is rejected

```zig
// -p=3000 has length > 2 → falls through to UnexpectedArgument
```

**Problem**: The handler only matches `arg.len == 2`. Any arg like `-p=3000` (len 7) skips the short flag handler entirely and hits `return Error.UnexpectedArgument`. This is the most natural syntax users will try first.

### 3. `-p value` (space-separated) is rejected

```zig
// -p passes null → MissingValue for non-bool types
// "3000" is never consumed — becomes an UnexpectedArgument
```

**Problem**: The second-most natural syntax. The value in the next arg is never looked at.

### 4. Combined short flags (`-vq`) are rejected

```zig
// -vq has length 3, not 2 → UnexpectedArgument
```

**Problem**: POSIX mandates that `tar -xzf`, `ls -la`, `rm -rf` work. Every CLI user expects `-vq` to mean `-v -q`. The current implementation rejects it because it only handles exactly 2-character args.

### 5. No aliasing — `-v` cannot mean `--verbose`

```zig
const Args = struct { verbose: bool = false };
// -v → UnknownFlag (no field named "v")
```

**Problem**: The most common use of short flags is as aliases: `-v` for `--verbose`, `-o` for `--output`, `-n` for `--name`. The current design requires the field itself to be named with a single character. You can have `-v` OR `--verbose`, but not both mapping to the same field.

### 6. Single-char fields create dual-path ambiguity

```zig
const Args = struct { v: bool = false };
// --v works (long flag path)
// -v also works (short flag path)
// Both set the same field. Two syntaxes, no way to distinguish.
```

**Problem**: A field named `v` is matched by both `--v` (long flag handler) and `-v` (short flag handler). This isn't a bug, but it means the user's struct design is overloaded — field naming now has parsing implications. A field named `n` means "I want a short flag" whether you intended that or not.

### 7. Bare `-` is an error

```zig
// "-" starts with "-", len != 2, falls to UnexpectedArgument
```

**Problem**: `-` is a Unix convention meaning "read from stdin". The short flag handler doesn't interfere with this, but the catch-all `-` check on line 177 (`if (std.mem.startsWith(u8, arg, "-")) return Error.UnexpectedArgument`) rejects it. This isn't caused by short flags specifically, but the short flag handler makes the `-` prefix handling more complex and harder to reason about.

---

## What the Ecosystem Does

### TigerBeetle (primary inspiration for this library)

**No short flags at all.** Long flags only (`--flag=value`). This is deliberate — TigerBeetle's design philosophy is "only one way to do things."

### n0s4/flags (community fork of TigerBeetle's approach)

Uses a **`pub const switches`** declaration for aliasing:

```zig
const Args = struct {
    verbose: bool = false,
    output: []const u8 = "out.txt",

    pub const switches = .{
        .verbose = 'v',
        .output = 'o',
    };
};
// -v maps to --verbose, -o maps to --output
// -vo works (combined)
// -o value works (value consumption)
```

This is a proper implementation: aliases are explicit, combining works, values work.

### Zig standard library proposal (#30677)

The proposed `std` CLI parser also uses a **declaration-based approach**:

```zig
pub const short = .{ .foo = 'f' };
```

Short flags were initially declared out of scope. Community feedback pushed for them, and the consensus was: aliasing via declaration, not single-char field names.

### Summary Table

| Library | Short flags? | Mechanism | `-p value`? | `-vq`? | Aliasing? |
|---------|-------------|-----------|-------------|--------|-----------|
| **TigerBeetle** | No | — | — | — | — |
| **n0s4/flags** | Yes | `pub const switches` | Yes | Yes | Yes |
| **Zig std proposal** | Planned | `pub const short` | Yes | Planned | Yes |
| **flags.zig (this)** | Partial | Single-char field names | No | No | No |

---

## Pros of Keeping Current Implementation

1. **Zero additional API surface**: No new declarations needed — a field named `v` just works as `-v`.
2. **Simple implementation**: 17 lines, no new concepts.
3. **Bool short flags work**: For the narrow case of `v: bool = false` + `-v`, it does what users expect.

## Cons of Keeping Current Implementation

1. **Bool-only**: Non-bool short flags compile but always fail at runtime. This is a silent trap.
2. **No value syntax**: Neither `-p=3000` nor `-p 3000` works. Short flags are useless for anything with a value.
3. **No combining**: `-vq` is rejected. This violates the most basic POSIX expectation.
4. **No aliasing**: The #1 use case (short alias for long flag) is impossible. You can't have both `-v` and `--verbose`.
5. **Naming pollution**: Field names serve double duty — they're both the API name in code AND the flag character. A field named `v` is meaningless in application code (`result.v` vs `result.verbose`).
6. **Dual-path ambiguity**: `--v` and `-v` both work but through different code paths. This complicates testing and reasoning.
7. **False confidence**: Users see "short flags" in the feature list and assume full POSIX-style support. When `-p=8080` fails, they think the library is broken.
8. **Maintenance cost**: The 17 lines interact with the `-` prefix checks on line 177, making that section harder to modify. Any future changes to positional or flag parsing must account for the short flag path.

---

## Recommendation: Remove

**Remove the current short flag implementation entirely.** The ratio of working cases to broken cases is roughly 1:6 (bool-only, no values, no combining, no aliasing, naming pollution, dual-path ambiguity).

The 17 lines of code save no one real work — a user who wants `v: bool = false` with `-v` can already use `--v` (which works via the long flag path for single-char field names). The short flag handler adds nothing that the long flag path doesn't already provide, except saving one character of input (`-v` vs `--v`).

### If Short Flags Are Needed Later

Implement proper aliasing via a `pub const short` declaration, similar to n0s4/flags and the Zig std proposal:

```zig
const Args = struct {
    verbose: bool = false,
    port: u16 = 8080,
    output: []const u8 = "out.txt",

    pub const short = .{
        .verbose = 'v',
        .port = 'p',
        .output = 'o',
    };
};

// -v → verbose = true
// -p 8080 or -p=8080 → port = 8080
// -vo out.txt → verbose = true, output = "out.txt"
```

This approach:
- Separates field naming from flag syntax (no naming pollution)
- Supports values (`-p 8080`)
- Supports combining (`-vq`)
- Is explicit (opt-in per field, not implicit from name length)
- Matches community direction (n0s4/flags, Zig std proposal)
- Can be added later without breaking the existing API

### What to Do Now

1. Delete lines 158–175 (the short flag handler)
2. Delete the `arg.len == 2` check
3. Remove the "short flags" test
4. Update README to remove short flag claims
5. Add "no short flags" to limitations (honestly this time)

The line `if (std.mem.startsWith(u8, arg, "-")) return Error.UnexpectedArgument;` on line 177 already handles all single-dash args correctly by rejecting them. That's the right behavior until proper short flags are implemented.
