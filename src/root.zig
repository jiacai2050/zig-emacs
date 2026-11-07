const std = @import("std");
const c = @import("c");

const plugin_is_GPL_compatible: c_int = 1;

pub fn module_init(comptime Module: type) void {
    // These exported variable and function are required by Emacs. See:
    // https://www.gnu.org/software/emacs/manual/html_node/elisp/Module-Initialization.html
    @export(&plugin_is_GPL_compatible, .{ .name = "plugin_is_GPL_compatible" });

    const Closure = struct {
        fn init(ert: ?*c.struct_emacs_runtime) callconv(.c) c_int {
            if (!@hasDecl(Module, "init")) {
                @compileError("Emacs dynamic module must provide an `init` function");
            }
            const env = Env.init(ert.?.get_environment.?(ert).?);
            return Module.init(env);
        }
    };
    @export(&Closure.init, .{ .name = "emacs_module_init" });
}

/// Emacs value used as argument or return type.
pub const Value = c.emacs_value;
pub const Integer = c.intmax_t;

pub const FuncContext = struct {
    doc_string: ?[:0]const u8 = null,
    interactive_spec: ?[:0]const u8 = null,
};

pub const FuncCallExit = enum(u32) {
    @"return",
    signal,
    throw,
};

pub const ProcessInputResult = enum(u32) {
    @"continue",
    quit,
};

const ptrdiff_t = c.ptrdiff_t;

pub const Env = struct {
    inner: *c.emacs_env,

    // Global references.
    nil: Value,
    t: Value,

    fn init(env: *c.emacs_env) Env {
        return .{
            .inner = env,
            .nil = env.make_global_ref.?(env, env.intern.?(env, "nil")),
            .t = env.make_global_ref.?(env, env.intern.?(env, "t")),
        };
    }

    // C type to Emacs.
    pub fn makeString(self: Env, input: [:0]const u8) Value {
        return self.inner.make_string.?(self.inner, input, @intCast(input.len));
    }

    pub fn makeInteger(self: Env, n: Integer) Value {
        return self.inner.make_integer.?(self.inner, n);
    }

    pub fn makeFloat(self: Env, n: f64) Value {
        return self.inner.make_float.?(self.inner, n);
    }

    // Emacs to C type.
    pub fn extractString(self: Env, allocator: std.mem.Allocator, v: Value) ![:0]const u8 {
        var len: ptrdiff_t = 0;
        // The first call asks Emacs for the required null-terminated size.
        if (!self.inner.copy_string_contents.?(self.inner, v, null, &len)) {
            return error.CopyStringContentsFailed;
        }
        if (len <= 0) {
            return error.InvalidStringLength;
        }
        const buf = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(buf);

        if (!self.inner.copy_string_contents.?(self.inner, v, buf.ptr, &len)) {
            return error.CopyStringContentsFailed;
        }
        return buf[0 .. buf.len - 1 :0];
    }

    pub fn extractInteger(self: Env, v: Value) Integer {
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

    pub fn funcall(self: Env, function_name: [:0]const u8, args: []Value) Value {
        return self.inner.funcall.?(
            self.inner,
            self.intern(function_name),
            @intCast(args.len),
            args.ptr,
        );
    }

    pub fn shouldQuit(self: Env) bool {
        if (self.inner.should_quit.?(self.inner)) {
            return true;
        }
        if (self.nonLocalExitCheck() != .@"return") {
            return true;
        }
        if (self.processInput() != .@"continue") {
            return true;
        }
        return false;
    }

    pub fn nonLocalExitCheck(self: Env) FuncCallExit {
        return @fromBackingInt(@intCast(self.inner.non_local_exit_check.?(self.inner)));
    }

    /// This function clears the pending nonlocal exit conditions and data from env.
    pub fn nonLocalExitClear(self: Env) void {
        return self.inner.non_local_exit_clear.?(self.inner);
    }

    pub fn nonLocalExitThrow(self: Env, tag: Value, value: Value) void {
        return self.inner.non_local_exit_throw.?(self.inner, tag, value);
    }

    pub fn nonLocalExitSignal(self: Env, symbol: Value, value: Value) void {
        return self.inner.non_local_exit_signal.?(self.inner, symbol, value);
    }

    pub fn processInput(self: Env) ProcessInputResult {
        return @fromBackingInt(@intCast(self.inner.process_input.?(self.inner)));
    }

    pub fn typeOf(self: Env, v: Value) Value {
        return self.inner.type_of.?(self.inner, v);
    }

    /// This function defines an Emacs module function.
    pub fn makeFunction(
        self: Env,
        comptime name: [:0]const u8,
        func: anytype,
        ctx: FuncContext,
    ) void {
        const fn_info = switch (@typeInfo(@TypeOf(func))) {
            .@"fn" => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (fn_info.is_generic) @compileError("emacs function can't be generic");
        if (fn_info.attrs.varargs) @compileError("emacs function can't be variadic");
        if (fn_info.param_types.len == 0) {
            @compileError("Emacs functions must contain at least one argument");
        }
        if (fn_info.param_types[0] != Env) {
            @compileError("The first Emacs function argument must have type Env");
        }
        if (fn_info.return_type) |ret_type| {
            if (ret_type != Value) {
                switch (@typeInfo(ret_type)) {
                    .error_union => |err_union| {
                        if (err_union.payload != Value) {
                            @compileError("Emacs functions must return Value or !Value");
                        }
                    },
                    else => @compileError("Emacs functions must return Value or !Value"),
                }
            }
        } else {
            @compileError("Emacs functions must return Value or !Value");
        }

        // The first function argument is the environment.
        const min_args: ptrdiff_t = @as(ptrdiff_t, @intCast(fn_info.param_types.len)) - 1;
        const max_args: ptrdiff_t = min_args;
        const emacs_fn = self.inner.make_function.?(
            self.inner,
            min_args,
            max_args,
            struct {
                fn makeFunctionCallback(
                    e: [*c]c.emacs_env,
                    nargs: ptrdiff_t,
                    emacs_args: [*c]Value,
                    data: ?*anyopaque,
                ) callconv(.c) Value {
                    if (e == null) {
                        std.log.err("Emacs passed a null environment", .{});
                        return null;
                    }
                    const zig_env = Env.init(e.?);
                    if (data != null) {
                        std.log.err("Emacs passed unexpected callback data", .{});
                        return zig_env.nil;
                    }
                    if (nargs != min_args) {
                        std.log.err("Emacs passed an unexpected argument count", .{});
                        return zig_env.nil;
                    }
                    if (min_args > 0) {
                        if (emacs_args == null) {
                            std.log.err("Emacs passed null arguments", .{});
                            return zig_env.nil;
                        }
                    }

                    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                    args[0] = zig_env;
                    comptime var i: usize = 0;
                    inline while (i < min_args) : (i += 1) {
                        // The first argument is the environment.
                        args[i + 1] = emacs_args[i];
                    }

                    if (zig_env.shouldQuit()) {
                        return zig_env.nil;
                    }

                    return if (fn_info.return_type.? == Value)
                        @call(.auto, func, args)
                    else
                        @call(.auto, func, args) catch |err| {
                            std.log.err(
                                "call function failed, func:{s}, err:{any}",
                                .{ name, err },
                            );
                            zig_env.signal(err, .{
                                zig_env.makeString("call function failed"),
                                zig_env.makeString(name),
                            });
                            return zig_env.nil;
                        };
                }
            }.makeFunctionCallback,
            @ptrCast(ctx.doc_string),
            null,
        );

        if (ctx.interactive_spec) |spec| {
            self.inner.make_interactive.?(self.inner, emacs_fn, self.makeString(spec));
        }
        var defalias_args = [_]Value{
            self.intern(name), emacs_fn,
        };
        _ = self.funcall("defalias", &defalias_args);
    }

    pub fn makeUserPointer(self: Env, user_ptr: *anyopaque, fin: anytype) Value {
        return self.inner.make_user_ptr.?(
            self.inner,
            struct {
                fn finalizer(ptr: ?*anyopaque) callconv(.c) void {
                    if (ptr) |p| {
                        @call(.auto, fin, .{p});
                    }
                }
            }.finalizer,
            user_ptr,
        );
    }
    pub fn getUserPointer(self: Env, v: Value) ?*anyopaque {
        return self.inner.get_user_ptr.?(self.inner, v);
    }

    pub fn message(self: Env, input: [:0]const u8) Value {
        var args = [_]Value{self.makeString(input)};
        return self.funcall("message", &args);
    }

    pub fn signal(self: Env, err: anyerror, args: anytype) void {
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        var data: [args_type_info.@"struct".field_names.len]Value = undefined;
        inline for (args_type_info.@"struct".field_names, 0..) |field_name, i| {
            data[i] = @field(args, field_name);
        }
        var symbol_args = [_]Value{self.makeString(@errorName(err))};
        const symbol = self.funcall("make-symbol", &symbol_args);
        self.nonLocalExitSignal(symbol, self.funcall("list", &data));
    }

    pub fn reportError(self: Env, comptime template: [:0]const u8, err: anyerror) Value {
        var args = [_]Value{
            self.makeString(template ++ "err:%s"),
            self.makeString(@errorName(err)),
        };
        return self.funcall(
            "error",
            &args,
        );
    }
};
