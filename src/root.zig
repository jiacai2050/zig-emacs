const std = @import("std");
const c = @cImport({
    @cInclude("emacs-module.h");
});
const root = @import("root");

/// This exported variable and func are required by emacs.
export const plugin_is_GPL_compatible: c_int = 1;
export fn emacs_module_init(ert: ?*c.struct_emacs_runtime) callconv(.C) c_int {
    if (!@hasDecl(root, "init")) @compileError("emacs dynamic module must provider function `init`");
    if (!@hasDecl(root, "allocator")) @compileError("emacs dynamic module must provide an allocator");

    return root.init(Env.init(
        ert.?.get_environment.?(ert).?,
        root.allocator,
    ));
}

pub const Value = c.emacs_value;
const ptrdiff_t = c_long;
const intmax_t = c_long;

pub const Env = struct {
    inner: *c.emacs_env,
    allocator: std.mem.Allocator,

    // global refs
    nil: Value,
    t: Value,

    fn init(env: *c.emacs_env, allocator: std.mem.Allocator) Env {
        return .{
            .inner = env,
            .allocator = allocator,
            .nil = env.make_global_ref.?(env, env.intern.?(env, "nil")),
            .t = env.make_global_ref.?(env, env.intern.?(env, "t")),
        };
    }

    // c type -> emacs
    pub fn makeString(self: Env, input: [:0]const u8) Value {
        return self.inner.make_string.?(self.inner, input, @intCast(input.len));
    }

    pub fn makeInteger(self: Env, n: c_long) Value {
        return self.inner.make_integer.?(self.inner, n);
    }

    pub fn makeFloat(self: Env, n: f64) Value {
        return self.inner.make_float.?(self.inner, n);
    }

    // emacs -> c type
    pub fn extractString(self: Env, allocator: std.mem.Allocator, v: Value) ![:0]const u8 {
        var len: c_long = 0;
        // pass null as buf to get len
        _ = self.inner.copy_string_contents.?(self.inner, v, null, &len);
        const buf = try allocator.alloc(u8, @intCast(len));

        // fill buf
        _ = self.inner.copy_string_contents.?(self.inner, v, buf.ptr, &len);
        return buf[0 .. buf.len - 1 :0];
    }

    pub fn extractInteger(self: Env, v: Value) c_long {
        return self.inner.extract_integer.?(self.inner, v);
    }

    pub fn extractFloat(self: Env, v: Value) f64 {
        return self.inner.extract_float.?(self.inner, v);
    }

    pub fn intern(self: Env, symbol: [:0]const u8) Value {
        return self.inner.intern.?(self.inner, symbol);
    }

    pub fn isNotNil(self: Env, v: Value) bool {
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
        return self.funcall("message", &[_]Value{self.makeString(input)});
    }

    pub fn defineFunc(
        self: Env,
        comptime name: [:0]const u8,
        func: anytype,
        ctx: FuncContext,
    ) Value {
        const fn_info = switch (@typeInfo(@TypeOf(func))) {
            .Fn => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (fn_info.is_generic) @compileError("emacs function can't be generic");
        if (fn_info.is_var_args) @compileError("emacs function can't be variadic");
        if (fn_info.params.len == 0) @compileError("emacs function should contains at least one arg");
        if (fn_info.params[0].type != Env) @compileError("emacs function first arg should be Env type");
        if (fn_info.return_type) |ret_type| {
            if (ret_type != Value) {
                switch (@typeInfo(ret_type)) {
                    .ErrorUnion => |err_union| {
                        if (err_union.payload != Value) {
                            @compileError("emacs function should return Value or !Value");
                        }
                    },
                    else => @compileError("emacs function should return Value or !Value"),
                }
            }
        } else {
            @compileError("emacs function should return Value or !Value");
        }

        const makeFunction = self.inner.make_function.?;
        // subtract the env argument
        const min_args: ptrdiff_t = @as(ptrdiff_t, @intCast(fn_info.params.len)) - 1;
        const max_args = min_args; // TODO: now we only support fixed number of args.
        const emacs_fn = makeFunction(
            self.inner,
            min_args,
            max_args,
            struct {
                fn emacs_fn(e: ?*c.emacs_env, nargs: ptrdiff_t, emacs_args: [*c]Value, data: ?*anyopaque) callconv(.C) Value {
                    _ = nargs;
                    _ = data;

                    const zig_env = Env.init(e.?, root.allocator);
                    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                    args[0] = zig_env;
                    comptime var i: usize = 0;
                    inline while (i < min_args) : (i += 1) {
                        // Remember the first argument is always the env
                        const arg = fn_info.params[i + 1];
                        const arg_ptr = &args[i + 1];
                        const ArgType = arg.type.?;

                        convertTypeFromEmacs(zig_env.allocator, ArgType, zig_env, arg_ptr, emacs_args[i].?) catch |err| {
                            std.log.err("convert value failed, func:{s}, err:{any}", .{ name, err });
                            return zig_env.report_error(
                                std.fmt.comptimePrint("convert value to zig failed, func:{s}", .{name}),
                                err,
                            );
                        };
                    }

                    return if (fn_info.return_type.? == Value)
                        @call(.auto, func, args)
                    else
                        @call(.auto, func, args) catch |err| {
                            std.log.err("call function failed, func:{s}, err:{any}", .{ name, err });
                            return zig_env.report_error(
                                std.fmt.comptimePrint("call function failed, func:{s}", .{name}),
                                err,
                            );
                        };
                }
            }.emacs_fn,
            @ptrCast(ctx.doc_string),
            null,
        );

        return self.funcall("defalias", &[_]Value{
            self.intern(name), emacs_fn,
        });
    }

    pub fn report_error(self: Env, comptime tmpl: [:0]const u8, err: anyerror) Value {
        return self.funcall("error", &[_]Value{ self.makeString(tmpl ++ "err:%s"), self.makeString(@errorName(err)) });
    }
};

/// This function convert Emacs type arg to Zig type.
fn convertTypeFromEmacs(allocator: std.mem.Allocator, comptime ArgType: type, env: Env, arg: *ArgType, v: Value) !void {
    switch (@typeInfo(ArgType)) {
        .Float => arg.* = env.extractFloat(v),
        .Int => arg.* = @intCast(env.extractInteger(v)),

        .Pointer => |ptr| switch (ptr.size) {
            .Slice => switch (ptr.child) {
                u8 => arg.* = try env.extractString(allocator, v),
                else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
            },
            else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
        },
        else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
    }
}

pub const FuncContext = struct {
    doc_string: ?[:0]const u8 = null,
};
