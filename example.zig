const std = @import("std");
const emacs = @import("emacs");

// Every module needs to call `moduleInit` in order to register with Emacs.
comptime {
    emacs.moduleInit(@This());
}

var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

const ModuleContext = struct {
    gpa: std.mem.Allocator,
};

var module_context = ModuleContext{
    .gpa = switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => safe_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    },
};

fn greeting(env: emacs.Env, value: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse {
        return error.MissingModuleContext;
    };
    const username = try env.extractString(context.gpa, value);
    defer context.gpa.free(username);

    const res = try env.formatString(context.gpa, "hello {s}!", .{username});
    _ = try env.funcall("message", &[_]emacs.Value{res});
    return res;
}

fn add(env: emacs.Env, first_value: emacs.Value, second_value: emacs.Value) emacs.Value {
    const first_number = env.extractInteger(first_value);
    const second_number = env.extractInteger(second_value);
    return env.makeInteger(first_number + second_number);
}

const Database = struct {
    // Identifies stale or incorrectly typed Emacs user pointers.
    const magic: u64 = 0x4442_5A49_4745_4D41;

    gpa: std.mem.Allocator,
    // Stores the marker used to validate this Database pointer.
    magic_value: u64,
    id: emacs.Integer,

    fn finalizer(self: *Database) void {
        if (self.magic_value != magic) {
            @panic("Invalid database pointer");
        }
        defer self.gpa.destroy(self);

        std.debug.print("Close db, id:{d}\n", .{self.id});
    }
};

fn makeDB(env: emacs.Env, value: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse {
        return error.MissingModuleContext;
    };
    const id = env.extractInteger(value);
    var db = try context.gpa.create(Database);
    db.gpa = context.gpa;
    db.magic_value = Database.magic;
    db.id = id;
    return env.makeUserPointer(Database, db, Database.finalizer);
}

fn saveTextToDB(
    env: emacs.Env,
    database_value: emacs.Value,
    body_value: emacs.Value,
) emacs.Value {
    const database = env.getUserPointer(Database, database_value) orelse {
        return env.reportError(
            "invalid database pointer: ",
            error.InvalidDatabasePointer,
        ) catch |err| {
            std.log.err("failed to report database error: {s}", .{@errorName(err)});
            return env.nil;
        };
    };
    if (database.magic_value != Database.magic) {
        return env.reportError(
            "invalid database pointer: ",
            error.InvalidDatabasePointer,
        ) catch |err| {
            std.log.err("failed to report database error: {s}", .{@errorName(err)});
            return env.nil;
        };
    }
    const body = env.extractInteger(body_value);
    std.debug.print("Save {d} to db({d})\n", .{ body, database.id });
    return env.t;
}

/// Sends text to an Emacs pipe process, where its process filter can handle it.
fn sendToChannel(
    env: emacs.Env,
    process_value: emacs.Value,
    message_value: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse {
        return error.MissingModuleContext;
    };
    var channel = try env.openChannel(process_value);
    defer channel.deinit() catch |err| {
        std.log.err("failed to close Emacs channel: {s}", .{@errorName(err)});
    };

    const message = try env.extractString(context.gpa, message_value);
    defer context.gpa.free(message);

    try channel.write(message);
    try channel.write("\n");
    return env.t;
}

// Emacs dynamic module entrypoint
/// Registers the example module functions with Emacs.
pub fn init(env: emacs.Env) c_int {
    std.debug.print("Init my module...\n", .{});

    env.makeFunction(
        "zig-greeting",
        greeting,
        .{
            .doc_string = "greeting written in Zig",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-add",
        add,
        // This make `zig-add` interactive.
        .{
            .interactive_spec = "nFirst number: \nnSecond number: ",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "make-db",
        makeDB,
        .{ .user_data = @ptrCast(&module_context) },
    ) catch return 1;
    env.makeFunction(
        "save-text-to-db",
        saveTextToDB,
        .{ .user_data = @ptrCast(&module_context) },
    ) catch return 1;
    env.makeFunction(
        "zig-send-to-channel",
        sendToChannel,
        .{
            .doc_string = "Send text to an Emacs pipe process filter.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-test-predicates",
        struct {
            fn testPredicates(env_arg: emacs.Env, val: emacs.Value) !emacs.Value {
                const items = [_]emacs.Value{
                    env_arg.boolean(env_arg.isNil(val)),
                    env_arg.boolean(env_arg.isInteger(val)),
                    env_arg.boolean(env_arg.isFloat(val)),
                    env_arg.boolean(env_arg.isNumber(val)),
                    env_arg.boolean(env_arg.isString(val)),
                    env_arg.boolean(env_arg.isSymbol(val)),
                    env_arg.boolean(env_arg.isVector(val)),
                    env_arg.boolean(env_arg.isUserPointer(val)),
                    env_arg.boolean(env_arg.isCons(val)),
                    env_arg.boolean(env_arg.isList(val)),
                };
                return env_arg.makeList(&items);
            }
        }.testPredicates,
        .{
            .doc_string = "Test type predicates on val.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-test-list-ops",
        struct {
            fn testListOps(env_arg: emacs.Env, val: emacs.Value) !emacs.Value {
                const context = env_arg.getUserData(ModuleContext) orelse return error.MissingModuleContext;
                const len = try env_arg.listLength(val);
                const items = try env_arg.extractList(context.gpa, val);
                defer context.gpa.free(items);

                var reversed = env_arg.nil;
                for (items) |item| {
                    reversed = try env_arg.cons(item, reversed);
                }

                const res = [_]emacs.Value{
                    env_arg.makeInteger(@intCast(len)),
                    reversed,
                };
                return env_arg.makeList(&res);
            }
        }.testListOps,
        .{
            .doc_string = "Test list operations on val.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-test-type-enum",
        struct {
            fn testTypeEnum(env_arg: emacs.Env, val: emacs.Value) emacs.Value {
                const t_name = switch (env_arg.getType(val)) {
                    .nil => "nil",
                    .integer => "integer",
                    .float => "float",
                    .string => "string",
                    .symbol => "symbol",
                    .vector => "vector",
                    .cons => "cons",
                    .user_ptr => "user_ptr",
                    .function => "function",
                    .other => "other",
                };
                return env_arg.makeString(t_name);
            }
        }.testTypeEnum,
        .{
            .doc_string = "Return type enum as string.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-test-sequence",
        struct {
            fn testSequence(env_arg: emacs.Env, val: emacs.Value) !emacs.Value {
                const context = env_arg.getUserData(ModuleContext) orelse return error.MissingModuleContext;
                const seq = env_arg.toSequence(val) orelse return env_arg.nil;
                const items = try seq.toSlice(context.gpa);
                defer context.gpa.free(items);

                // Return a Vector containing the items
                const vec = try emacs.Vector.create(env_arg, items);
                return vec.value;
            }
        }.testSequence,
        .{
            .doc_string = "Test Sequence abstraction by converting to Vector.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    return 0;
}
