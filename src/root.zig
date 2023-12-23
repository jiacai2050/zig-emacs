const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("emacs-module.h");
});
const root = @import("root");

export const plugin_is_GPL_compatible: c_int = 1;
const ptrdiff_t = c_long;
const intmax_t = c_long;
pub const Value = c.emacs_value;

const EmacsFunction = *const fn (
    [*c]c.emacs_env,
    ptrdiff_t, // required args
    [*c]c.emacs_value, // array of the function arguments
    ?*anyopaque,
) callconv(.C) c.emacs_value;

export fn emacs_module_init(ert: ?*c.struct_emacs_runtime) callconv(.C) c_int {
    const rt = ert.?;
    root.init(Env.init(rt.get_environment.?(ert).?));
    return 0;
}

pub const Env = struct {
    inner: *c.emacs_env,

    // c type -> emacs
    make_string: *const fn ([*c]c.emacs_env, [*c]const u8, c_long) callconv(.C) c.emacs_value,
    make_function: *const fn (
        [*c]c.emacs_env,
        ptrdiff_t, // minimum and maximum number of arguments
        ptrdiff_t, // `emacs_variadic_function` means `&rest`
        ?EmacsFunction,
        [*c]const u8, // docstring
        ?*anyopaque, // arbitrary additional data to be passed to func
    ) callconv(.C) c.emacs_value,
    make_integer: *const fn ([*c]c.emacs_env, intmax_t) callconv(.C) c.emacs_value,
    make_float: *const fn ([*c]c.emacs_env, f64) callconv(.C) c.emacs_value,

    // emacs -> c type
    copy_string_contents: *const fn ([*c]c.emacs_env, c.emacs_value, [*c]u8, [*c]ptrdiff_t) callconv(.C) bool,
    extract_integer: *const fn ([*c]c.emacs_env, c.emacs_value) callconv(.C) intmax_t,
    extract_float: *const fn ([*c]c.emacs_env, c.emacs_value) callconv(.C) f64,

    // utils
    nil: c.emacs_value,
    funcall: *const fn ([*c]c.emacs_env, c.emacs_value, c_long, [*c]c.emacs_value) callconv(.C) c.emacs_value,
    intern: *const fn ([*c]c.emacs_env, [*c]const u8) callconv(.C) c.emacs_value,
    is_not_nil: *const fn ([*c]c.emacs_env, c.emacs_value) callconv(.C) bool,
    eq: *const fn ([*c]c.emacs_env, c.emacs_value, c.emacs_value) callconv(.C) bool,

    fn init(env: *c.emacs_env) Env {
        return .{
            .inner = env,
            .make_function = env.make_function.?,
            .make_string = env.make_string.?,
            .make_integer = env.make_integer.?,
            .make_float = env.make_float.?,
            .copy_string_contents = env.copy_string_contents.?,
            .extract_integer = env.extract_integer.?,
            .extract_float = env.extract_float.?,
            .nil = env.intern.?(env, "nil"),
            .funcall = env.funcall.?,
            .intern = env.intern.?,
            .is_not_nil = env.is_not_nil.?,
            .eq = env.eq.?,
        };
    }

    pub fn define_fn(self: @This(), comptime name: [:0]const u8, func: anytype) void {
        const fn_info = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (fn_info.is_generic) @compileError("emacs function can't be generic");
        if (fn_info.is_var_args) @compileError("emacs function can't be variadic");
        if (fn_info.params.len == 0) @compileError("emacs function should contains at least one arg");
        if (fn_info.params[0].type != Env) @compileError("emacs function first arg should be Env type");

        const min_args: ptrdiff_t = @intCast(fn_info.params.len) - 1;
        const max_args = min_args;
        const emacs_fn = self.make_function(
            self.inner,
            min_args,
            max_args,
            struct {
                fn emacs_fn(e: ?*c.emacs_env, nargs: ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.C) c.emacs_value {
                    const inner_env = Env.init(e.?);
                    _ = nargs;
                    _ = args;
                    _ = data;
                    return @call(.auto, func, .{inner_env});
                }
            }.emacs_fn,
            null,
            null,
        );
        _ = self.funcall(
            self.inner,
            self.intern(self.inner, "defalias"),
            2,
            @constCast(&[_]c.emacs_value{
                self.intern(self.inner, name), emacs_fn,
            }),
        );
        // std.debug.print("Define fn, name:{s}, body:{any}\n", .{ name, func });
    }
};
