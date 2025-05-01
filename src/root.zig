const std = @import("std");
const c = @cImport({
    @cInclude("emacs-module.h");
});

const plugin_is_GPL_compatible: c_int = 1;

pub fn module_init(comptime Module: type) void {
    // Those exported variable and func are required by emacs. See:
    // https://www.gnu.org/software/emacs/manual/html_node/elisp/Module-Initialization.html
    @export(&plugin_is_GPL_compatible, .{ .name = "plugin_is_GPL_compatible" });

    const Closure = struct {
        fn init(ert: ?*c.struct_emacs_runtime) callconv(.C) c_int {
            if (!@hasDecl(Module, "init")) @compileError("emacs dynamic module must provider function `init`");
            const env = Env.init(ert.?.get_environment.?(ert).?);
            return Module.init(env);
        }
    };
    @export(&Closure.init, .{ .name = "emacs_module_init" });
}

/// Emacs value used as argument or return type.
pub const Value = c.emacs_value;

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

const ptrdiff_t = c_long;
const intmax_t = c_long;

pub const Env = struct {
    inner: *c.emacs_env,

    // global refs
    nil: Value,
    t: Value,

    fn init(env: *c.emacs_env) Env {
        return .{
            .inner = env,
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

    pub fn shouldQuit(self: Env) bool {
        return self.inner.should_quit.?(self.inner) or self.nonLocalExitCheck() != .@"return" or self.processInput() != .@"continue";
    }

    pub fn nonLocalExitCheck(self: Env) FuncCallExit {
        return @enumFromInt(self.inner.non_local_exit_check.?(self.inner));
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
        return @enumFromInt(self.inner.process_input.?(self.inner));
    }

    pub fn typeOf(self: Env, v: Value) Value {
        return self.inner.type_of.?(self.inner, v);
    }

    /// This function define a module function.
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
        if (fn_info.is_var_args) @compileError("emacs function can't be variadic");
        if (fn_info.params.len == 0) @compileError("emacs function should contains at least one arg");
        if (fn_info.params[0].type != Env) @compileError("emacs function first arg should be Env type");
        if (fn_info.return_type) |ret_type| {
            if (ret_type != Value) {
                switch (@typeInfo(ret_type)) {
                    .error_union => |err_union| {
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

        // subtract the env argument
        const min_args: ptrdiff_t = @as(ptrdiff_t, @intCast(fn_info.params.len)) - 1;
        const max_args = min_args; // TODO: now we only support fixed number of args.
        const emacs_fn = self.inner.make_function.?(
            self.inner,
            min_args,
            max_args,
            struct {
                fn emacs_fn(e: ?*c.emacs_env, nargs: ptrdiff_t, emacs_args: [*c]Value, data: ?*anyopaque) callconv(.C) Value {
                    _ = nargs;
                    _ = data;

                    const zig_env = Env.init(e.?);
                    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                    args[0] = zig_env;
                    comptime var i: usize = 0;
                    inline while (i < min_args) : (i += 1) {
                        // Remember the first argument is always the env
                        args[i + 1] = emacs_args[i];
                    }

                    if (zig_env.shouldQuit()) {
                        return zig_env.nil;
                    }

                    return if (fn_info.return_type.? == Value)
                        @call(.auto, func, args)
                    else
                        @call(.auto, func, args) catch |err| {
                            std.log.err("call function failed, func:{s}, err:{any}", .{ name, err });
                            zig_env.signal(err, .{
                                zig_env.makeString("call function failed"),
                                zig_env.makeString(name),
                            });
                            return zig_env.nil;
                        };
                }
            }.emacs_fn,
            @ptrCast(ctx.doc_string),
            null,
        );

        if (ctx.interactive_spec) |spec| {
            self.inner.make_interactive.?(self.inner, emacs_fn, self.makeString(spec));
        }
        _ = self.funcall("defalias", &[_]Value{
            self.intern(name), emacs_fn,
        });

        return;
    }

    pub fn makeUserPointer(self: Env, user_ptr: *anyopaque, fin: anytype) Value {
        return self.inner.make_user_ptr.?(
            self.inner,
            struct {
                fn finalizer(ptr: ?*anyopaque) callconv(.C) void {
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
        return self.funcall("message", &[_]Value{self.makeString(input)});
    }

    pub fn signal(self: Env, err: anyerror, args: anytype) void {
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        var data: [args_type_info.@"struct".fields.len]Value = undefined;
        inline for (args_type_info.@"struct".fields, 0..) |fld, i| {
            data[i] = @field(args, fld.name);
        }
        const symbol = self.funcall("make-symbol", &[_]Value{self.makeString(@errorName(err))});
        self.nonLocalExitSignal(symbol, self.funcall("list", &data));
    }

    pub fn reportError(self: Env, comptime tmpl: [:0]const u8, err: anyerror) Value {
        return self.funcall("error", &[_]Value{ self.makeString(tmpl ++ "err:%s"), self.makeString(@errorName(err)) });
    }
};

/// This function convert Emacs type arg to Zig type.
/// Not used for now
fn convertTypeFromEmacs(allocator: ?std.mem.Allocator, comptime ArgType: type, env: Env, arg: *ArgType, v: Value) !void {
    switch (@typeInfo(ArgType)) {
        .float => arg.* = env.extractFloat(v),
        .int => arg.* = @intCast(env.extractInteger(v)),
        .pointer => |ptr| switch (ptr.size) {
            .slice => switch (ptr.child) {
                u8 => arg.* = blk: {
                    if (allocator) |ally| {
                        break :blk try env.extractString(ally, v);
                    } else {
                        return error.MissingAllocator;
                    }
                },
                else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
            },
            .one => arg.* = blk: {
                break :blk @ptrCast(@alignCast(env.getUserPointer(v)));
                // TODO: handle null?
                // break :blk if (env.getUserPointer(v)) |p|
                //     @ptrCast(@alignCast(env.getUserPointer(p)))
                // else
                //     null;
            },
            else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
        },
        else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
    }
}

// TODO: How to encapuslate a user pointer?
// pub const UserPointer =  struct {
//     ptr: *anyopaque,
//     finalizer: ?*const fn (ptr: *anyopaque) void = null,

//     fn deinit(self: UserPointer) void {
//         if (self.finalizer) |fin| {
//             @call(.auto, fin, .{self.ptr});
//         }
//     }
// };
