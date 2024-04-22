const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("emacs", .{
        .root_source_file = b.path("src/root.zig"),
    });
    module.addIncludePath(b.path("include"));

    const exe = b.addSharedLibrary(.{
        .name = "zig-example",
        .root_source_file = b.path("example.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("emacs", module);
    exe.linkLibC();
    b.installArtifact(exe);
}
