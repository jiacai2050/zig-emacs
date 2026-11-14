const std = @import("std");
const emacs = @import("emacs");
const matcher = @import("matcher.zig");

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

fn fuzzyScore(env: emacs.Env, candidate_val: emacs.Value, query_val: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const candidate = try env.extractString(context.gpa, candidate_val);
    defer context.gpa.free(candidate);

    const query = try env.extractString(context.gpa, query_val);
    defer context.gpa.free(query);

    if (matcher.score(candidate, query)) |s| {
        return env.makeInteger(@intCast(s));
    }
    return env.nil;
}

fn fuzzyMatchVector(
    env: emacs.Env,
    candidates_val: emacs.Value,
    query_val: emacs.Value,
    limit_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const count = env.vectorSize(candidates_val);
    if (count <= 0) {
        var empty_args = [_]emacs.Value{};
        return try env.funcall("vector", &empty_args);
    }

    const query = try env.extractString(context.gpa, query_val);
    defer context.gpa.free(query);

    var limit: ?usize = null;
    if (env.isNotNil(limit_val)) {
        const lim_int = env.extractInteger(limit_val);
        if (lim_int > 0) {
            limit = @intCast(lim_int);
        }
    }

    // Extract candidates into slice
    const usize_count: usize = @intCast(count);
    var candidate_list = try context.gpa.alloc([:0]const u8, usize_count);
    defer {
        for (candidate_list[0..usize_count]) |item| {
            context.gpa.free(item);
        }
        context.gpa.free(candidate_list);
    }

    // Also keep track of the original emacs values to avoid re-creating strings
    var original_values = try context.gpa.alloc(emacs.Value, usize_count);
    defer context.gpa.free(original_values);

    var i: isize = 0;
    while (i < count) : (i += 1) {
        const item_val = env.vectorGet(candidates_val, i);
        original_values[@intCast(i)] = item_val;
        candidate_list[@intCast(i)] = try env.extractString(context.gpa, item_val);
    }

    // Collect matches with their original index
    const MatchWithIndex = struct {
        score: i32,
        index: usize,
    };

    var matches = std.ArrayList(MatchWithIndex).empty;
    defer matches.deinit(context.gpa);

    for (candidate_list, 0..) |cand, idx| {
        if (matcher.score(cand, query)) |s| {
            try matches.append(context.gpa, .{
                .score = s,
                .index = idx,
            });
        }
    }

    const sortFn = struct {
        fn sort(_: void, lhs: MatchWithIndex, rhs: MatchWithIndex) bool {
            return lhs.score > rhs.score;
        }
    }.sort;

    const matched_items = try matches.toOwnedSlice(context.gpa);
    defer context.gpa.free(matched_items);
    std.mem.sort(MatchWithIndex, matched_items, {}, sortFn);

    const result_count = if (limit) |lim|
        @min(lim, matched_items.len)
    else
        matched_items.len;

    // Create resulting Emacs vector using funcall make-vector and vectorSet
    var make_vec_args = [_]emacs.Value{
        env.makeInteger(@intCast(result_count)),
        env.nil,
    };
    const result_vec = try env.funcall("make-vector", &make_vec_args);

    var res_idx: usize = 0;
    while (res_idx < result_count) : (res_idx += 1) {
        const orig_idx = matched_items[res_idx].index;
        env.vectorSet(result_vec, @intCast(res_idx), original_values[orig_idx]);
    }

    return result_vec;
}

pub fn init(env: emacs.Env) c_int {
    env.makeFunction(
        "zig-fuzzy-score",
        fuzzyScore,
        .{
            .doc_string = "Compute fuzzy match score between candidate and query. Returns integer or nil.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-fuzzy-match-vector",
        fuzzyMatchVector,
        .{
            .doc_string = "Match candidates vector against query and return a sorted vector of matched strings.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    return 0;
}
