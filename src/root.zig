const std = @import("std");
const c = @cImport({
    @cInclude("emacs-module.h");
});
const root = @import("root");

export const plugin_is_GPL_compatible: c_int = 1;
pub const Value = c.emacs_value;
const ptrdiff_t = c_long;
const intmax_t = c_long;

// args: env, nargs: ptrdiff_t, fn: [*c]Value, data:?*anyopaque
const EmacsFunction = c.emacs_function;

export fn emacs_module_init(ert: ?*c.struct_emacs_runtime) callconv(.C) c_int {
    if (!@hasDecl(root, "init")) @compileError("emacs dynamic module must contains `fn init(env) c_int` entrypoint");

    const rt = ert.?;
    return root.init(Env.init(rt.get_environment.?(ert).?));
}

pub const Env = struct {
    inner: *c.emacs_env,

    make_function: *const fn (
        [*c]c.emacs_env,
        ptrdiff_t, // minimum and maximum number of arguments
        ptrdiff_t, // `emacs_variadic_function` means `&rest`
        EmacsFunction,
        [*c]const u8, // docstring
        ?*anyopaque, // arbitrary additional data to be passed to func
    ) callconv(.C) c.emacs_value,

    // global refs
    nil: c.emacs_value,
    t: c.emacs_value,

    // c type -> emacs
    pub fn make_string(self: Env, input: [:0]const u8) Value {
        return self.inner.make_string.?(self.inner, input, @intCast(input.len));
    }

    pub fn make_integer(self: Env, n: c_long) Value {
        return self.inner.make_integer.?(self.inner, n);
    }

    pub fn make_float(self: Env, n: f64) Value {
        return self.inner.make_float.?(self.inner, n);
    }

    // emacs -> c type
    pub fn extract_string(self: Env, allocator: std.mem.Allocator, v: Value) ![:0]const u8 {
        var len: c_long = 0;
        _ = self.inner.copy_string_contents.?(self.inner, v, null, &len);
        var buf = try allocator.alloc(u8, @intCast(len));

        _ = self.inner.copy_string_contents.?(self.inner, v, &buf, &len);
        return buf;
    }

    pub fn extract_integer(self: Env, v: Value) c_long {
        return self.inner.extract_integer.?(self.inner, v);
    }

    pub fn extract_float(self: Env, v: Value) f64 {
        return self.inner.extract_float.?(self.inner, v);
    }

    pub fn intern(self: Env, symbol: [:0]const u8) Value {
        return self.inner.intern.?(self.inner, symbol);
    }

    pub fn is_not_nil(self: Env, v: Value) bool {
        return self.inner.is_not_nil.?(v);
    }

    pub fn eq(self: Env, lhs: Value, rhs: Value) bool {
        return self.inner.eq.?(lhs, rhs);
    }

    pub fn funcall(self: Env, fn_name: [:0]const u8, args: []const Value) Value {
        return self.inner.funcall.?(
            self.inner,
            self.intern(fn_name),
            @intCast(args.len),
            @constCast(args.ptr),
        );
    }

    pub fn message(self: Env, input: [:0]const u8) Value {
        return self.funcall("message", &[_]Value{self.make_string(input)});
    }

    fn init(env: *c.emacs_env) Env {
        return .{
            .inner = env,
            .make_function = env.make_function.?,
            .nil = env.make_global_ref.?(env, env.intern.?(env, "nil")),
            .t = env.make_global_ref.?(env, env.intern.?(env, "t")),
        };
    }

    pub fn define_fn(self: @This(), comptime name: [:0]const u8, func: anytype) Value {
        const fn_info = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (fn_info.is_generic) @compileError("emacs function can't be generic");
        if (fn_info.is_var_args) @compileError("emacs function can't be variadic");
        if (fn_info.params.len == 0) @compileError("emacs function should contains at least one arg");
        if (fn_info.params[0].type != Env) @compileError("emacs function first arg should be Env type");

        // subtract the env argument
        const min_args: ptrdiff_t = @as(ptrdiff_t, @intCast(fn_info.params.len)) - 1;
        const max_args = min_args; // TODO: support &rest args
        const emacs_fn = self.make_function(
            self.inner,
            min_args,
            max_args,
            struct {
                fn emacs_fn(e: ?*c.emacs_env, nargs: ptrdiff_t, emacs_args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.C) c.emacs_value {
                    _ = data;
                    _ = nargs;

                    const zig_env = Env.init(e.?);
                    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                    args[0] = zig_env;
                    comptime var i: usize = 0;
                    inline while (i < min_args) : (i += 1) {
                        // Remember the first argument is always the env
                        const arg = fn_info.params[i + 1];
                        const arg_ptr = &args[i + 1];
                        const ArgType = arg.type.?;

                        setTypeFromValue(ArgType, zig_env, arg_ptr, emacs_args[i].?);
                    }
                    return @call(.auto, func, args);
                }
            }.emacs_fn,
            null,
            null,
        );
        return self.funcall("defalias", &[_]c.emacs_value{
            self.intern(name), emacs_fn,
        });
    }
};

fn setTypeFromValue(comptime ArgType: type, env: Env, arg: *ArgType, v: Value) void {
    switch (@typeInfo(ArgType)) {
        .Float => arg.* = env.extract_float(v),
        .Int => arg.* = @intCast(env.extract_integer(v)),

        // .Pointer => |ptr| switch (ptr.size) {
        //     .Slice => switch (ptr.child) {
        //         u8 => arg.* = sliceFromValue(sqlite_value),
        //         else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
        //     },
        //     else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
        // },
        else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
    }
}
