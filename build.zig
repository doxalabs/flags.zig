const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags_mod = b.addModule("flags", .{
        .root_source_file = b.path("src/flags.zig"),
        .target = target,
        .optimize = optimize,
    });

    const flags_tests = b.addTest(.{ .root_module = flags_mod });

    // A run step that will run the test executable.
    const run_flags_tests = b.addRunArtifact(flags_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_flags_tests.step);

    const example_mod = b.addModule("example", .{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
    });

    example_mod.addImport("flags", flags_mod);
    const example = b.addExecutable(.{
        .name = "demo",
        .root_module = example_mod,
    });
    const run_example = b.addRunArtifact(example);

    if (b.args) |args| run_example.addArgs(args);

    const example_step = b.step("example", "Run the demo example");
    example_step.dependOn(&run_example.step);
}
