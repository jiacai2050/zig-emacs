const std = @import("std");
const emacs = @import("emacs");
pub usingnamespace emacs;

pub fn init(env: emacs.Env) void {
    env.define_fn("test-func", "haha");
    std.debug.print("{s}\n", .{"hello emacs"});
}
test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
