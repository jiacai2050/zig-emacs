const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("emacs", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });
    module.addIncludePath(b.path("include"));

    const exe = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "emacs", .module = module },
            },
        }),
    });
    b.installArtifact(exe);

    const doc_object = b.addObject(.{
        .name = "docs",
        .root_module = module,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_object.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
