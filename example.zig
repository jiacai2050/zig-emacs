const std = @import("std");
const emacs = @import("emacs");

// Every module needs to call `module_init` in order to register with Emacs.
comptime {
    emacs.module_init(@This());
}

var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

pub const allocator = gpa: {
    break :gpa switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => safe_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => {
            break :gpa std.heap.smp_allocator;
        },
    };
};

fn greeting(e: emacs.Env, value: emacs.Value) !emacs.Value {
    const username = try e.extractString(allocator, value);
    defer allocator.free(username);

    const msg = try allocator.printSentinel("hello {s}!", .{username}, 0);
    defer allocator.free(msg);

    _ = e.message(msg);
    return e.makeString(msg);
}

fn add(env: emacs.Env, first_value: emacs.Value, second_value: emacs.Value) emacs.Value {
    const first_number = env.extractInteger(first_value);
    const second_number = env.extractInteger(second_value);
    return env.makeInteger(first_number + second_number);
}

const Database = struct {
    id: emacs.Integer,
    fn finalizer(ptr: *anyopaque) void {
        const self: *Database = @ptrCast(@alignCast(ptr));
        defer allocator.destroy(self);

        std.debug.print("Close db, id:{d}\n", .{self.id});
    }
};

fn makeDB(e: emacs.Env, value: emacs.Value) !emacs.Value {
    const id = e.extractInteger(value);
    var db = try allocator.create(Database);
    db.id = id;
    return e.makeUserPointer(db, Database.finalizer);
}

fn saveTextToDB(
    env: emacs.Env,
    database_value: emacs.Value,
    body_value: emacs.Value,
) emacs.Value {
    const user_pointer = env.getUserPointer(database_value) orelse {
        return env.reportError("invalid database pointer: ", error.InvalidDatabasePointer);
    };
    const db: *Database = @ptrCast(@alignCast(user_pointer));
    const body = env.extractInteger(body_value);
    std.debug.print("Save {d} to db({d})\n", .{ body, db.id });
    return env.t;
}

// Emacs dynamic module entrypoint
pub fn init(env: emacs.Env) c_int {
    std.debug.print("Init my module...\n", .{});

    env.makeFunction(
        "zig-greeting",
        greeting,
        .{ .doc_string = "greeting written in Zig" },
    );

    env.makeFunction(
        "zig-add",
        add,
        // This make `zig-add` interactive.
        .{ .interactive_spec = "nFirst number: \nnSecond number: " },
    );

    env.makeFunction("make-db", makeDB, .{});
    env.makeFunction("save-text-to-db", saveTextToDB, .{});
    env.makeFunction("zig-deinit", deinit, .{});

    return 0;
}

fn deinit(env: emacs.Env) emacs.Value {
    switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => {
            if (safe_allocator.deinit() != 0) {
                @panic("Memory leak detected");
            }
        },
        .ReleaseFast, .ReleaseSmall => {},
    }

    return env.nil;
}
