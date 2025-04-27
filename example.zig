const std = @import("std");
const emacs = @import("emacs");

// Every module needs to call `module_init` in order to register with Emacs.
comptime {
    emacs.module_init();
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var is_debug = true;

// `zig-emacs` require an `allocator`.
pub const allocator = gpa: {
    break :gpa switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => {
            is_debug = false;
            break :gpa std.heap.smp_allocator;
        },
    };
};

fn greeting(e: emacs.Env, value: emacs.Value) !emacs.Value {
    const username = try e.extractString(allocator, value);
    defer allocator.free(username);

    const msg = try std.fmt.allocPrintZ(
        allocator,
        "hello {s}!",
        .{username},
    );
    defer allocator.free(msg);

    _ = e.message(msg);
    return e.makeString(msg);
}

fn add(e: emacs.Env, v1: emacs.Value, v2: emacs.Value) emacs.Value {
    const a = e.extractInteger(v1);
    const b = e.extractInteger(v2);
    return e.makeInteger(a + b);
}

const Database = struct {
    id: c_long,
    fn finalizer(ptr: *anyopaque) void {
        const self: *Database = @ptrCast(@alignCast(ptr));
        defer allocator.destroy(self);

        std.debug.print("Close db, id:{d}\n", .{self.id});
    }

    fn userPointer(self: *Database) emacs.UserPointer {
        return .{
            .ptr = self,
            .finalizer = finalizer,
        };
    }
};

fn make_db(e: emacs.Env, value: emacs.Value) !emacs.Value {
    const id = e.extractInteger(value);
    var db = try allocator.create(Database);
    db.id = id;
    return e.makeUserPointer(db, Database.finalizer);
}

fn save_text_to_db(e: emacs.Env, v1: emacs.Value, v2: emacs.Value) emacs.Value {
    const db: *Database = @alignCast(@ptrCast(e.getUserPointer(v1)));
    const body = e.extractInteger(v2);
    std.debug.print("Save {d} to db({d})\n", .{ body, db.id });
    return e.t;
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

    env.makeFunction(
        "make-db",
        make_db,
        .{},
    );
    env.makeFunction(
        "save-text-to-db",
        save_text_to_db,
        .{},
    );

    if (is_debug) {
        // TODO: Trace/BPT trap: 5
        // if (debug_allocator.deinit() != .ok) {
        //     @panic("mem leaked!");
        // }
    }
    return 0;
}
