const std = @import("std");

/// Configures the Emacs module library and documentation build steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/emacs-module.h"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("emacs", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });

    // 1. Example dynamic module
    const example_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig-example",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "emacs", .module = module },
            },
        }),
    });
    b.installArtifact(example_lib);

    // 2. zig-fuzzy plugin module
    const fuzzy_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig-fuzzy",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/zig-fuzzy/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "emacs", .module = module },
            },
        }),
    });
    b.installArtifact(fuzzy_lib);

    // 3. zig-shelf plugin module
    const shelf_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zig-shelf",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/zig-shelf/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "emacs", .module = module },
            },
        }),
    });
    b.installArtifact(shelf_lib);

    // 4. Native unit tests for plugins
    const matcher_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/zig-fuzzy/matcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_matcher_test = b.addRunArtifact(matcher_test);

    const storage_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/zig-shelf/storage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_storage_test = b.addRunArtifact(storage_test);

    const unit_test_step = b.step("test-unit", "Run native Zig unit tests");
    unit_test_step.dependOn(&run_matcher_test.step);
    unit_test_step.dependOn(&run_storage_test.step);

    // 5. Documentation
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
