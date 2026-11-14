const std = @import("std");
const emacs = @import("emacs");
const storage = @import("storage.zig");
const Storage = storage.Storage;

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

fn shelfFinalizer(store: *Storage) void {
    if (store.magic_value != Storage.magic) return;
    store.deinit();
}

fn getValidStorage(env: emacs.Env, val: emacs.Value) ?*Storage {
    const store = env.getUserPointer(Storage, val) orelse return null;
    if (store.magic_value != Storage.magic) return null;
    return store;
}

fn shelfOpen(env: emacs.Env) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const store = try Storage.init(context.gpa);
    return env.makeUserPointer(Storage, store, shelfFinalizer);
}

fn shelfClose(env: emacs.Env, shelf_val: emacs.Value) !emacs.Value {
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };
    store.deinit();
    env.setUserPointer(Storage, shelf_val, null);
    return env.t;
}

fn shelfPut(
    env: emacs.Env,
    shelf_val: emacs.Value,
    key_val: emacs.Value,
    data_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };

    const key = try env.extractString(context.gpa, key_val);
    defer context.gpa.free(key);

    const data = try env.extractString(context.gpa, data_val);
    defer context.gpa.free(data);

    try store.put(key, data);
    return env.t;
}

fn shelfGet(
    env: emacs.Env,
    shelf_val: emacs.Value,
    key_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };

    const key = try env.extractString(context.gpa, key_val);
    defer context.gpa.free(key);

    const val = store.get(context.gpa, key);
    if (val) |v| {
        defer context.gpa.free(v);
        // Create null-terminated string for Emacs
        const sentinel_val = try context.gpa.allocSentinel(u8, v.len, 0);
        defer context.gpa.free(sentinel_val);
        @memcpy(sentinel_val, v);
        return env.makeString(sentinel_val);
    }
    return env.nil;
}

fn shelfDelete(
    env: emacs.Env,
    shelf_val: emacs.Value,
    key_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };

    const key = try env.extractString(context.gpa, key_val);
    defer context.gpa.free(key);

    return if (store.delete(key)) env.t else env.nil;
}

fn shelfCount(
    env: emacs.Env,
    shelf_val: emacs.Value,
) !emacs.Value {
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };
    return env.makeInteger(@intCast(store.count()));
}

const ScanWorker = struct {
    allocator: std.mem.Allocator,
    storage: *Storage,
    prefix: [:0]const u8,
    channel: emacs.Channel,

    fn run(self: *ScanWorker) void {
        defer {
            self.allocator.free(self.prefix);
            var ch = self.channel;
            ch.deinit() catch {};
            self.allocator.destroy(self);
        }

        self.storage.lock.lock();
        var it = self.storage.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (self.prefix.len == 0 or std.mem.startsWith(u8, k, self.prefix)) {
                self.channel.write(k) catch break;
                self.channel.write("\t") catch break;
                self.channel.write(entry.value_ptr.*) catch break;
                self.channel.write("\n") catch break;
            }
        }
        self.storage.lock.unlock();

        // End of stream marker
        self.channel.write("__SHELF_DONE__\n") catch {};
    }
};

fn shelfScanAsync(
    env: emacs.Env,
    shelf_val: emacs.Value,
    prefix_val: emacs.Value,
    proc_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const store = getValidStorage(env, shelf_val) orelse {
        return env.reportError("invalid shelf pointer: ", error.InvalidShelfPointer);
    };

    const prefix = try env.extractString(context.gpa, prefix_val);
    errdefer context.gpa.free(prefix);

    const channel = try env.openChannel(proc_val);

    const worker = try context.gpa.create(ScanWorker);
    worker.* = .{
        .allocator = context.gpa,
        .storage = store,
        .prefix = prefix,
        .channel = channel,
    };

    const thread = try std.Thread.spawn(.{}, ScanWorker.run, .{worker});
    thread.detach();

    return env.t;
}

pub fn init(env: emacs.Env) c_int {
    env.makeFunction(
        "zig-shelf-open",
        shelfOpen,
        .{
            .doc_string = "Open a new in-memory shelf store and return its user pointer.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-close",
        shelfClose,
        .{
            .doc_string = "Close a shelf store and release its memory.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-put",
        shelfPut,
        .{
            .doc_string = "Store a key-value string pair into shelf.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-get",
        shelfGet,
        .{
            .doc_string = "Retrieve a value by key from shelf, or nil if not found.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-delete",
        shelfDelete,
        .{
            .doc_string = "Delete a key from shelf.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-count",
        shelfCount,
        .{
            .doc_string = "Return total count of keys in shelf.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-shelf-scan-async",
        shelfScanAsync,
        .{
            .doc_string = "Asynchronously scan keys with prefix and write results to pipe process channel.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    return 0;
}
