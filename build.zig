const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("emacs", .{
        .source_file = .{ .path = "src/root.zig" },
    });

    // const lib_unit_tests = b.addTest(.{
    //     .root_source_file = .{ .path = "src/root.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_lib_unit_tests.step);

    const exe = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = .{ .path = "example.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addIncludePath(.{ .path = "include" });
    exe.addModule("emacs", module);
    b.installArtifact(exe);
}
