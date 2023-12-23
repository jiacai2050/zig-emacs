const std = @import("std");
const emacs = @import("emacs");
pub usingnamespace emacs;

pub fn init(env: emacs.Env) void {
    env.define_fn(
        "test-func",
        struct {
            fn f(e: emacs.Env) emacs.Value {
                const name = "hello emacs from zig";
                var args = [_]emacs.Value{
                    e.make_string(e.inner, name.ptr, @intCast(name.len)),
                };
                return e.funcall(
                    e.inner,
                    e.intern(e.inner, "message"),
                    1,
                    &args,
                );
            }
        }.f,
    );
}
