const std = @import("std");

pub const MatchResult = struct {
    candidate: []const u8,
    score: i32,
};

/// Computes a fuzzy matching score for candidate against query.
/// Returns null if query is not a subsequence of candidate.
/// Higher score indicates a better match.
pub fn score(candidate: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (candidate.len < query.len) return null;

    // Smart case: if query contains any uppercase char, do case-sensitive match;
    // otherwise do case-insensitive match.
    var is_case_sensitive = false;
    for (query) |ch| {
        if (std.ascii.isUpper(ch)) {
            is_case_sensitive = true;
            break;
        }
    }

    var query_idx: usize = 0;
    var total_score: i32 = 0;
    var consecutive: i32 = 0;
    var prev_matched_idx: ?usize = null;

    for (candidate, 0..) |cand_ch, cand_idx| {
        if (query_idx >= query.len) break;

        const target_ch = query[query_idx];
        const matched = if (is_case_sensitive)
            cand_ch == target_ch
        else
            std.ascii.toLower(cand_ch) == std.ascii.toLower(target_ch);

        if (matched) {
            var char_score: i32 = 10;

            // Consecutive match bonus
            if (prev_matched_idx) |prev| {
                if (cand_idx == prev + 1) {
                    consecutive += 1;
                    char_score += 15 * consecutive;
                } else {
                    consecutive = 0;
                }
            } else {
                // First matched character bonus if at prefix
                if (cand_idx == 0) {
                    char_score += 20;
                }
            }

            // Word boundary bonus: preceded by separator or camelCase transition
            if (cand_idx > 0) {
                const prev_ch = candidate[cand_idx - 1];
                if (isSeparator(prev_ch)) {
                    char_score += 25;
                } else if (std.ascii.isLower(prev_ch) and std.ascii.isUpper(cand_ch)) {
                    char_score += 20;
                }
            }

            total_score += char_score;
            prev_matched_idx = cand_idx;
            query_idx += 1;
        }
    }

    if (query_idx < query.len) {
        return null; // Not all query characters matched
    }

    // Length penalty: candidates closer to query length rank higher
    const extra_len: i32 = @intCast(candidate.len - query.len);
    total_score -= extra_len * 2;

    return total_score;
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\' or ch == '-' or ch == '_' or ch == '.' or ch == ' ';
}

fn sortDesc(_: void, lhs: MatchResult, rhs: MatchResult) bool {
    if (lhs.score != rhs.score) {
        return lhs.score > rhs.score;
    }
    // Stable order by length and alphabetical
    if (lhs.candidate.len != rhs.candidate.len) {
        return lhs.candidate.len < rhs.candidate.len;
    }
    return std.mem.order(u8, lhs.candidate, rhs.candidate) == .lt;
}

/// Matches all candidates against query and returns the sorted top results.
pub fn matchAll(
    allocator: std.mem.Allocator,
    candidates: []const []const u8,
    query: []const u8,
    max_results: ?usize,
) ![]MatchResult {
    var matches = std.ArrayList(MatchResult).empty;
    defer matches.deinit(allocator);

    for (candidates) |cand| {
        if (score(cand, query)) |s| {
            try matches.append(allocator, .{
                .candidate = cand,
                .score = s,
            });
        }
    }

    const items = try matches.toOwnedSlice(allocator);
    std.mem.sort(MatchResult, items, {}, sortDesc);

    if (max_results) |limit| {
        if (limit < items.len) {
            // Realloc or slice
            return items[0..limit];
        }
    }
    return items;
}

test "score matching" {
    // Exact match
    try std.testing.expect(score("src/root.zig", "root") != null);
    // Boundary match
    const b_score = score("src/root.zig", "rz").?;
    const no_boundary = score("src/root.zig", "oi").?;
    try std.testing.expect(b_score > no_boundary);

    // Subsequence failure
    try std.testing.expect(score("src/root.zig", "xyz") == null);
}

test "smart case" {
    try std.testing.expect(score("Main.zig", "main") != null);
    try std.testing.expect(score("main.zig", "Main") == null);
}
