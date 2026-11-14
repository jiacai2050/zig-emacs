const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const Storage = struct {
    pub const magic: u64 = 0x5348_454C_465A_4947; // "SHELFZIG"

    allocator: std.mem.Allocator,
    magic_value: u64,
    lock: SpinLock,
    map: std.StringHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) !*Storage {
        const self = try allocator.create(Storage);
        self.* = .{
            .allocator = allocator,
            .magic_value = magic,
            .lock = .{},
            .map = .{},
        };
        return self;
    }

    pub fn deinit(self: *Storage) void {
        self.lock.lock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        self.magic_value = 0;
        self.lock.unlock();

        self.allocator.destroy(self);
    }

    pub fn put(self: *Storage, key: []const u8, value: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if key already exists
        if (self.map.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.allocator.dupe(u8, value);
            return;
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const owned_val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_val);

        try self.map.put(self.allocator, owned_key, owned_val);
    }

    pub fn get(self: *Storage, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();

        const val = self.map.get(key) orelse return null;
        return allocator.dupe(u8, val) catch null;
    }

    pub fn delete(self: *Storage, key: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }

    pub fn count(self: *Storage) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.map.count();
    }
};

test "storage basic crud" {
    const allocator = std.testing.allocator;
    const store = try Storage.init(allocator);
    defer store.deinit();

    try store.put("foo", "bar");
    try store.put("key2", "value2");
    try std.testing.expectEqual(@as(usize, 2), store.count());

    const val = store.get(allocator, "foo");
    try std.testing.expect(val != null);
    defer allocator.free(val.?);
    try std.testing.expectEqualStrings("bar", val.?);

    const deleted = store.delete("foo");
    try std.testing.expect(deleted);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "thread spawn" {
    const worker = struct {
        fn run(val: *usize) void {
            val.* += 1;
        }
    }.run;
    var count_val: usize = 0;
    const thread = try std.Thread.spawn(.{}, worker, .{&count_val});
    thread.join();
    try std.testing.expectEqual(@as(usize, 1), count_val);
}
