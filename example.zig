const std = @import("std");
const emacs = @import("emacs");

// Every module needs to call `module_init` in order to register with Emacs.
comptime {
    emacs.module_init(@This());
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

    const msg = try context.gpa.printSentinel("hello {s}!", .{username}, 0);
    defer context.gpa.free(msg);

    _ = try env.message(msg);
    return env.makeString(msg);
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

    return 0;
}
