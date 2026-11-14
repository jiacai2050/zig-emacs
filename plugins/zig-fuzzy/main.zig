const std = @import("std");
const emacs = @import("emacs");
const matcher = @import("matcher.zig");

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
    const seq = env.toSequence(candidates_val) orelse {
        const empty_vec = try emacs.Vector.createEmpty(env, 0);
        return empty_vec.value;
    };

    const original_values = try seq.toSlice(context.gpa);
    defer context.gpa.free(original_values);

    if (original_values.len == 0) {
        const empty_vec = try emacs.Vector.createEmpty(env, 0);
        return empty_vec.value;
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

    const count = original_values.len;
    var candidate_list = try context.gpa.alloc([:0]const u8, count);
    defer {
        for (candidate_list) |item| {
            context.gpa.free(item);
        }
        context.gpa.free(candidate_list);
    }

    for (original_values, 0..) |item_val, i| {
        candidate_list[i] = try env.extractString(context.gpa, item_val);
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

    const MatchSorter = struct {
        fn desc(_: void, lhs: MatchWithIndex, rhs: MatchWithIndex) bool {
            return lhs.score > rhs.score;
        }
    };

    const matched_items = try matches.toOwnedSlice(context.gpa);
    defer context.gpa.free(matched_items);
    std.mem.sort(MatchWithIndex, matched_items, {}, MatchSorter.desc);

    const result_count = if (limit) |lim|
        @min(lim, matched_items.len)
    else
        matched_items.len;

    const result_vec = try emacs.Vector.createEmpty(env, result_count);
    for (0..result_count) |res_idx| {
        result_vec.set(res_idx, original_values[matched_items[res_idx].index]);
    }

    return result_vec.value;
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
