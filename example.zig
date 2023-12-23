const std = @import("std");
const emacs = @import("emacs");
usingnamespace emacs;

// Emacs dynamic module entrypoint
pub fn init(env: emacs.Env) c_int {
    _ = env.define_fn(
        "zig-func",
        struct {
            fn f(e: emacs.Env) emacs.Value {
                return e.message("hello emacs from zig");
            }
        }.f,
    );

    _ = env.define_fn(
        "zig-add",
        struct {
            fn f(e: emacs.Env, a: i32, b: i32) emacs.Value {
                return e.make_integer(a + b);
            }
        }.f,
    );

    return 0;
}
