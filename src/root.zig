const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("emacs-module.h");
});
const root = @import("root");

export const plugin_is_GPL_compatible: c_int = 1;

export fn emacs_module_init(ert: ?*c.struct_emacs_runtime) callconv(.C) c_int {
    const rt = ert.?;
    root.init(Env.init(rt.get_environment.?(ert).?));
    return 0;
}

pub const Env = struct {
    inner: *c.emacs_env,

    nil: c.emacs_value,
    make_string: *const fn ([*c]c.emacs_env, [*c]const u8, c_long) callconv(.C) c.emacs_value,
    funcall: *const fn ([*c]c.emacs_env, c.emacs_value, c_long, [*c]c.emacs_value) callconv(.C) c.emacs_value,
    intern: *const fn ([*c]c.emacs_env, [*c]const u8) callconv(.C) c.emacs_value,

    fn init(env: *c.emacs_env) Env {
        return .{
            .inner = env,
            .nil = env.intern.?(env, "nil"),
            .make_string = env.make_string.?,
            .funcall = env.funcall.?,
            .intern = env.intern.?,
        };
    }

    pub fn define_fn(self: @This(), name: []const u8, func: anytype) void {
        var args = [_]c.emacs_value{
            self.make_string(self.inner, name.ptr, @intCast(name.len)),
        };
        _ = self.funcall(
            self.inner,
            self.intern(self.inner, "message"),
            1,
            &args,
        );
        std.debug.print("Define fn, name:{s}, body:{any}\n", .{ name, func });
    }
};
