const std = @import("std");
const emacs = @import("emacs");
usingnamespace emacs;

// This is required by emacs zig module.
pub const allocator = std.heap.c_allocator;

fn greeting(e: emacs.Env, username: []const u8) !emacs.Value {
    // `[]const u8` is allcated by emacs zig module, we need to ensure
    // is freed.
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

fn add(e: emacs.Env, a: i32, b: i32) emacs.Value {
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

fn make_db(e: emacs.Env, id: c_long) !emacs.Value {
    var db = try allocator.create(Database);
    db.id = id;
    return e.makeUserPointer(db, Database.finalizer);
}

fn save_text_to_db(e: emacs.Env, db: *Database, body: c_long) emacs.Value {
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
    return 0;
}
