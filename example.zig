const std = @import("std");
const emacs = @import("emacs");
usingnamespace emacs;

// This is required by emacs zig module.
pub const allocator = std.heap.c_allocator;

fn greeting(e: emacs.Env, username: []const u8) !emacs.Value {
    // `[]const u8` is allcated by emacs zig module, we need to ensure
    // is freed.
    defer allocator.free(username);

    const msg = try std.fmt.allocPrintZ(
        allocator,
        "hello {s}!",
        .{username},
    );
    defer allocator.free(msg);

    _ = e.message(msg);
    return e.makeString(msg);
}

fn add(e: emacs.Env, a: i32, b: i32) emacs.Value {
    return e.makeInteger(a + b);
}

// Emacs dynamic module entrypoint
pub fn init(env: emacs.Env) c_int {
    env.defineFunc(
        "zig-greeting",
        greeting,
        .{ .doc_string = "greeting written in Zig" },
    );

    env.defineFunc(
        "zig-add",
        add,
        // This make `zig-add` interactive.
        .{ .interactive_spec = "nFirst number: \nnSecond number: " },
    );

    return 0;
}
