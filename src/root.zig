const std = @import("std");
const c = @import("c");

const plugin_is_GPL_compatible: c_int = 1;

/// Exports the Emacs module entry points for the given module implementation.
pub fn module_init(comptime Module: type) void {
    // These exported variable and function are required by Emacs. See:
    // https://www.gnu.org/software/emacs/manual/html_node/elisp/Module-Initialization.html
    @export(&plugin_is_GPL_compatible, .{ .name = "plugin_is_GPL_compatible" });

    const Closure = struct {
        fn init(ert: ?*c.struct_emacs_runtime) callconv(.c) c_int {
            if (!@hasDecl(Module, "init")) {
                @compileError("Emacs dynamic module must provide an `init` function");
            }
            const env = Env.init(ert.?.get_environment.?(ert).?, null);
            return Module.init(env);
        }
    };
    @export(&Closure.init, .{ .name = "emacs_module_init" });
}

/// Opaque Emacs Lisp value used as an argument or return type.
pub const Value = c.emacs_value;

/// Integer type used by Emacs Lisp.
pub const Integer = i64;

/// Limb type used by the Emacs big integer API.
pub const Limb = usize;

/// Time representation used by the Emacs time API.
pub const Time = struct {
    seconds: i64,
    nanoseconds: i64,
};

/// C callback used for Emacs user pointers and functions.
pub const Finalizer = *const fn (?*anyopaque) callconv(.c) void;

/// Errors returned while managing an Emacs pipe channel.
pub const ChannelError = error{
    OpenFailed,
    CloseFailed,
};

/// Owns the native file descriptor returned by Emacs open_channel.
pub const Channel = struct {
    file_descriptor: i32,

    /// Releases the channel and closes its native file descriptor.
    pub fn deinit(channel: *Channel) ChannelError!void {
        if (channel.file_descriptor < 0) {
            return;
        }

        const result = std.c.close(@intCast(channel.file_descriptor));
        if (result != 0) {
            return error.CloseFailed;
        }
        channel.file_descriptor = -1;
    }
};

/// Metadata used when registering a Zig function with Emacs.
pub const FuncContext = struct {
    /// Optional documentation string shown by Emacs.
    doc_string: ?[:0]const u8 = null,
    /// Optional interactive specification for commands.
    interactive_spec: ?[:0]const u8 = null,
    /// Opaque module context passed to the function callback.
    user_data: ?*anyopaque = null,
};

/// Result of checking whether an Emacs function returned, signaled, or threw.
pub const FuncCallExit = enum(u32) {
    @"return",
    signal,
    throw,
};

/// Result of checking whether Emacs requested that module code stop.
pub const ProcessInputResult = enum(u32) {
    @"continue",
    quit,
};

/// Errors returned when an Emacs function call exits non-locally.
pub const FuncallError = error{
    EmacsSignal,
    EmacsThrow,
};

/// Details returned by an Emacs non-local exit.
pub const NonLocalExit = struct {
    kind: FuncCallExit,
    symbol: Value,
    data: Value,
};

const Index = isize;

/// Borrowed handle to the current Emacs execution environment.
pub const Env = struct {
    inner: *c.emacs_env,
    user_data: ?*anyopaque,

    nil: Value,
    t: Value,

    fn init(env: *c.emacs_env, user_data: ?*anyopaque) Env {
        return .{
            .inner = env,
            .user_data = user_data,
            .nil = env.intern.?(env, "nil"),
            .t = env.intern.?(env, "t"),
        };
    }

    // C type to Emacs.
    /// Creates an Emacs string from a null-terminated UTF-8 string.
    pub fn makeString(self: Env, input: [:0]const u8) Value {
        return self.inner.make_string.?(self.inner, input, @intCast(input.len));
    }

    /// Creates an Emacs unibyte string from arbitrary bytes.
    pub fn makeUnibyteString(self: Env, input: []const u8) Value {
        return self.inner.make_unibyte_string.?(
            self.inner,
            input.ptr,
            @intCast(input.len),
        );
    }

    /// Creates an Emacs integer.
    pub fn makeInteger(self: Env, n: Integer) Value {
        return self.inner.make_integer.?(self.inner, @intCast(n));
    }

    /// Creates an Emacs floating-point value.
    pub fn makeFloat(self: Env, n: f64) Value {
        return self.inner.make_float.?(self.inner, n);
    }

    // Emacs to C type.
    /// Copies an Emacs string into allocator-owned, null-terminated memory.
    pub fn extractString(self: Env, allocator: std.mem.Allocator, v: Value) ![:0]const u8 {
        var len: Index = 0;
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

    /// Extracts an integer from an Emacs value.
    pub fn extractInteger(self: Env, v: Value) Integer {
        return @intCast(self.inner.extract_integer.?(self.inner, v));
    }

    /// Extracts a floating-point value from an Emacs value.
    pub fn extractFloat(self: Env, v: Value) f64 {
        return self.inner.extract_float.?(self.inner, v);
    }

    /// Interns a null-terminated symbol name in Emacs.
    pub fn intern(self: Env, symbol: [:0]const u8) Value {
        return self.inner.intern.?(self.inner, symbol);
    }

    /// Returns whether an Emacs value is not nil.
    pub fn isNotNil(self: Env, v: Value) bool {
        return self.inner.is_not_nil.?(self.inner, v);
    }

    /// Compares two Emacs values for identity.
    pub fn eq(self: Env, lhs: Value, rhs: Value) bool {
        return self.inner.eq.?(self.inner, lhs, rhs);
    }

    /// Calls an Emacs function and reports non-local exits as errors.
    pub fn funcall(
        self: Env,
        function_name: [:0]const u8,
        args: []Value,
    ) FuncallError!Value {
        const value = self.inner.funcall.?(
            self.inner,
            self.intern(function_name),
            @intCast(args.len),
            args.ptr,
        );
        return switch (self.nonLocalExitCheck()) {
            .@"return" => value,
            .signal => error.EmacsSignal,
            .throw => error.EmacsThrow,
        };
    }

    /// Returns whether the current callback should stop processing.
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

    /// Returns the current non-local exit status.
    pub fn nonLocalExitCheck(self: Env) FuncCallExit {
        return @fromBackingInt(@intCast(self.inner.non_local_exit_check.?(self.inner)));
    }

    /// Returns the current non-local exit and its associated values.
    pub fn nonLocalExitGet(self: Env) NonLocalExit {
        var symbol: Value = null;
        var data: Value = null;
        const kind: FuncCallExit = @fromBackingInt(@intCast(
            self.inner.non_local_exit_get.?(self.inner, &symbol, &data),
        ));
        return .{
            .kind = kind,
            .symbol = symbol,
            .data = data,
        };
    }

    /// This function clears the pending nonlocal exit conditions and data from env.
    /// Clears the current non-local exit.
    pub fn nonLocalExitClear(self: Env) void {
        return self.inner.non_local_exit_clear.?(self.inner);
    }

    /// Requests a non-local throw from the current Emacs callback.
    pub fn nonLocalExitThrow(self: Env, tag: Value, value: Value) void {
        return self.inner.non_local_exit_throw.?(self.inner, tag, value);
    }

    /// Requests a non-local signal from the current Emacs callback.
    pub fn nonLocalExitSignal(self: Env, symbol: Value, value: Value) void {
        return self.inner.non_local_exit_signal.?(self.inner, symbol, value);
    }

    /// Creates a global reference that protects a value from garbage collection.
    pub fn makeGlobalRef(self: Env, value: Value) Value {
        return self.inner.make_global_ref.?(self.inner, value);
    }

    /// Releases a global reference created by makeGlobalRef.
    pub fn freeGlobalRef(self: Env, value: Value) void {
        self.inner.free_global_ref.?(self.inner, value);
    }

    /// Returns whether Emacs requested that the callback yield.
    pub fn processInput(self: Env) ProcessInputResult {
        return @fromBackingInt(@intCast(self.inner.process_input.?(self.inner)));
    }

    /// Returns the Emacs type of a value.
    pub fn typeOf(self: Env, v: Value) Value {
        return self.inner.type_of.?(self.inner, v);
    }

    /// Registers a fixed-arity Zig function as an Emacs function.
    pub fn makeFunction(
        self: Env,
        comptime name: [:0]const u8,
        func: anytype,
        ctx: FuncContext,
    ) FuncallError!void {
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
        const min_args: Index = @as(Index, @intCast(fn_info.param_types.len)) - 1;
        const max_args: Index = min_args;
        const emacs_fn = self.inner.make_function.?(
            self.inner,
            min_args,
            max_args,
            struct {
                fn makeFunctionCallback(
                    e: [*c]c.emacs_env,
                    nargs: Index,
                    emacs_args: [*c]Value,
                    data: ?*anyopaque,
                ) callconv(.c) Value {
                    if (e == null) {
                        std.log.err("Emacs passed a null environment", .{});
                        return null;
                    }
                    const zig_env = Env.init(e.?, data);
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
                            }) catch |signal_err| {
                                std.log.err(
                                    "failed to signal function error: {s}",
                                    .{@errorName(signal_err)},
                                );
                            };
                            return zig_env.nil;
                        };
                }
            }.makeFunctionCallback,
            @ptrCast(ctx.doc_string),
            ctx.user_data,
        );

        if (ctx.interactive_spec) |spec| {
            self.inner.make_interactive.?(self.inner, emacs_fn, self.makeString(spec));
        }
        var defalias_args = [_]Value{
            self.intern(name), emacs_fn,
        };
        _ = try self.funcall("defalias", &defalias_args);
    }

    /// Creates a typed Emacs user pointer with an optional finalizer.
    pub fn makeUserPointer(
        self: Env,
        comptime T: type,
        pointer: *T,
        comptime finalizer: ?*const fn (*T) void,
    ) Value {
        const FinalizerCallback = struct {
            fn callback(raw_pointer: ?*anyopaque) callconv(.c) void {
                if (raw_pointer) |raw| {
                    const typed_pointer: *T = @ptrCast(@alignCast(raw));
                    if (finalizer) |destroy| {
                        destroy(typed_pointer);
                    }
                }
            }
        };
        const callback = if (finalizer == null) null else FinalizerCallback.callback;
        return self.inner.make_user_ptr.?(
            self.inner,
            callback,
            pointer,
        );
    }

    /// Replaces the pointer stored in an Emacs user pointer.
    pub fn setUserPointer(
        self: Env,
        comptime T: type,
        value: Value,
        pointer: ?*T,
    ) void {
        const raw_pointer: ?*anyopaque = if (pointer) |typed_pointer|
            @ptrCast(typed_pointer)
        else
            null;
        self.inner.set_user_ptr.?(self.inner, value, raw_pointer);
    }

    /// Returns a typed pointer stored in an Emacs user pointer.
    pub fn getUserPointer(self: Env, comptime T: type, value: Value) ?*T {
        const raw_pointer = self.inner.get_user_ptr.?(self.inner, value);
        if (raw_pointer) |raw| {
            return @ptrCast(@alignCast(raw));
        }
        return null;
    }

    /// Returns the finalizer attached to an Emacs user pointer.
    pub fn getUserFinalizer(self: Env, value: Value) ?Finalizer {
        return self.inner.get_user_finalizer.?(self.inner, value);
    }

    /// Replaces the finalizer attached to an Emacs user pointer.
    pub fn setUserFinalizer(self: Env, value: Value, finalizer: ?Finalizer) void {
        self.inner.set_user_finalizer.?(self.inner, value, finalizer);
    }

    /// Returns an element from an Emacs vector.
    pub fn vectorGet(self: Env, vector: Value, index: Index) Value {
        return self.inner.vec_get.?(self.inner, vector, index);
    }

    /// Replaces an element in an Emacs vector.
    pub fn vectorSet(self: Env, vector: Value, index: Index, value: Value) void {
        self.inner.vec_set.?(self.inner, vector, index, value);
    }

    /// Returns the number of elements in an Emacs vector.
    pub fn vectorSize(self: Env, vector: Value) Index {
        return self.inner.vec_size.?(self.inner, vector);
    }

    /// Returns the callback context as the requested type.
    pub fn getUserData(self: Env, comptime T: type) ?*T {
        const user_data = self.user_data orelse return null;
        return @ptrCast(@alignCast(user_data));
    }

    /// Calls the Emacs `message` function.
    pub fn message(self: Env, input: [:0]const u8) FuncallError!Value {
        var args = [_]Value{self.makeString(input)};
        return self.funcall("message", &args);
    }

    /// Signals an error with the supplied Emacs error arguments.
    pub fn signal(self: Env, err: anyerror, args: anytype) FuncallError!void {
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
        const symbol = try self.funcall("make-symbol", &symbol_args);
        const signal_data = try self.funcall("list", &data);
        self.nonLocalExitSignal(symbol, signal_data);
    }

    /// Reports a Zig error through the Emacs `error` function.
    pub fn reportError(
        self: Env,
        comptime template: [:0]const u8,
        err: anyerror,
    ) FuncallError!Value {
        var args = [_]Value{
            self.makeString(template ++ "err:%s"),
            self.makeString(@errorName(err)),
        };
        return self.funcall(
            "error",
            &args,
        );
    }

    /// Extracts an Emacs time value.
    pub fn extractTime(self: Env, value: Value) Time {
        const time = self.inner.extract_time.?(self.inner, value);
        return .{
            .seconds = @intCast(time.tv_sec),
            .nanoseconds = @intCast(time.tv_nsec),
        };
    }

    /// Creates an Emacs time value.
    pub fn makeTime(self: Env, time: Time) Value {
        const c_time: c.struct_timespec = .{
            .tv_sec = @intCast(time.seconds),
            .tv_nsec = @intCast(time.nanoseconds),
        };
        return self.inner.make_time.?(self.inner, c_time);
    }

    /// Extracts a big integer into a caller-provided limb buffer.
    pub fn extractBigInteger(
        self: Env,
        value: Value,
        sign: *i32,
        count: *Index,
        magnitude: []Limb,
    ) bool {
        return self.inner.extract_big_integer.?(
            self.inner,
            value,
            sign,
            count,
            magnitude.ptr,
        );
    }

    /// Creates an Emacs big integer from a sign and limb buffer.
    pub fn makeBigInteger(
        self: Env,
        sign: i32,
        magnitude: []const Limb,
    ) Value {
        return self.inner.make_big_integer.?(
            self.inner,
            sign,
            @intCast(magnitude.len),
            magnitude.ptr,
        );
    }

    /// Returns the finalizer attached to an Emacs function value.
    pub fn getFunctionFinalizer(self: Env, function: Value) ?Finalizer {
        return self.inner.get_function_finalizer.?(self.inner, function);
    }

    /// Replaces the finalizer attached to an Emacs function value.
    pub fn setFunctionFinalizer(
        self: Env,
        function: Value,
        finalizer: ?Finalizer,
    ) void {
        self.inner.set_function_finalizer.?(self.inner, function, finalizer);
    }

    /// Opens the write end of an Emacs `make-pipe-process` pipe.
    ///
    /// The returned channel lets native code, including a background thread,
    /// send bytes to the process filter registered on the Emacs side. The
    /// caller owns the channel and must close it when communication ends.
    pub fn openChannel(self: Env, pipe_process: Value) ChannelError!Channel {
        const file_descriptor = self.inner.open_channel.?(self.inner, pipe_process);
        if (file_descriptor < 0) {
            return error.OpenFailed;
        }
        return .{ .file_descriptor = @intCast(file_descriptor) };
    }

    /// Marks an Emacs function as interactive with the given specification.
    pub fn makeInteractive(self: Env, function: Value, spec: Value) void {
        self.inner.make_interactive.?(self.inner, function, spec);
    }
};
