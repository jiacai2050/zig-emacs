const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("emacs", .{
        .source_file = .{ .path = "src/root.zig" },
    });

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
