const std = @import("std");
const emacs = @import("emacs");
usingnamespace emacs;

pub const allocator = std.heap.c_allocator;

// Emacs dynamic module entrypoint
pub fn init(env: emacs.Env) c_int {
    _ = env.defineFunc(
        "zig-greeting",
        struct {
            fn f(e: emacs.Env, username: []const u8) !emacs.Value {
                defer allocator.free(username);

                const greeting = try std.fmt.allocPrintZ(
                    allocator,
                    "hello {s}!",
                    .{username},
                );
                defer allocator.free(greeting);

                return e.message(greeting);
            }
        }.f,
        .{ .doc_string = "greet written in Zig" },
    );

    _ = env.defineFunc(
        "zig-add",
        struct {
            fn f(e: emacs.Env, a: i32, b: i32) emacs.Value {
                return e.makeInteger(a + b);
            }
        }.f,
        .{},
    );

    return 0;
}
