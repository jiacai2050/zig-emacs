const std = @import("std");
const emacs = @import("emacs");
const sqlite = @import("sqlite");
const c = sqlite.c;

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

pub const SQLiteDb = struct {
    pub const magic: u64 = 0x5351_4C49_5445_5A49; // "SQLITEZI"

    magic_value: u64,
    allocator: std.mem.Allocator,
    db: sqlite.Database,

    pub fn deinit(self: *SQLiteDb) void {
        if (self.magic_value != magic) return;
        self.magic_value = 0;
        self.db.close();
        self.allocator.destroy(self);
    }
};

fn sqliteFinalizer(db: *SQLiteDb) void {
    db.deinit();
}

fn getValidDb(env: emacs.Env, val: emacs.Value) ?*SQLiteDb {
    const db = env.getUserPointer(SQLiteDb, val) orelse return null;
    if (db.magic_value != SQLiteDb.magic) return null;
    return db;
}

fn sqliteP(env: emacs.Env, val: emacs.Value) emacs.Value {
    return if (getValidDb(env, val) != null) env.t else env.nil;
}

fn sqliteOpen(env: emacs.Env, path_val: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;

    var db_opt: sqlite.Database.Options = .{};
    var owned_path: ?[:0]const u8 = null;
    defer {
        if (owned_path) |p| context.gpa.free(p);
    }

    if (env.isNotNil(path_val)) {
        owned_path = try env.extractString(context.gpa, path_val);
        db_opt.path = owned_path.?.ptr;
        db_opt.mode = .ReadWrite;
        db_opt.create = true;
    }

    const native_db = sqlite.Database.open(db_opt) catch |err| {
        return env.reportError("failed to open sqlite database: ", err);
    };

    const wrapper = try context.gpa.create(SQLiteDb);
    wrapper.* = .{
        .magic_value = SQLiteDb.magic,
        .allocator = context.gpa,
        .db = native_db,
    };

    return env.makeUserPointer(SQLiteDb, wrapper, sqliteFinalizer);
}

fn sqliteClose(env: emacs.Env, db_val: emacs.Value) !emacs.Value {
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };
    db.deinit();
    env.setUserPointer(SQLiteDb, db_val, null);
    return env.t;
}

fn bindValues(env: emacs.Env, allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, values_val: emacs.Value) !void {
    if (!env.isNotNil(values_val)) return;

    // Check if values is vector or list
    const is_vec = blk: {
        var args = [_]emacs.Value{values_val};
        const res = try env.funcall("vectorp", &args);
        break :blk env.isNotNil(res);
    };

    var values_list = std.ArrayList(emacs.Value).empty;
    defer values_list.deinit(allocator);

    if (is_vec) {
        const count = env.vectorSize(values_val);
        var i: isize = 0;
        while (i < count) : (i += 1) {
            try values_list.append(allocator, env.vectorGet(values_val, i));
        }
    } else {
        // Assume list: iterate using car and cdr
        var cur = values_val;
        while (env.isNotNil(cur)) {
            var car_args = [_]emacs.Value{cur};
            const item = try env.funcall("car", &car_args);
            try values_list.append(allocator, item);

            var cdr_args = [_]emacs.Value{cur};
            cur = try env.funcall("cdr", &cdr_args);
        }
    }

    // Bind each value (1-indexed in SQLite)
    for (values_list.items, 0..) |v, idx| {
        const param_idx: c_int = @intCast(idx + 1);

        if (!env.isNotNil(v)) {
            _ = c.sqlite3_bind_null(stmt, param_idx);
            continue;
        }

        // Determine type of v
        var int_args = [_]emacs.Value{v};
        const is_int = env.isNotNil(try env.funcall("integerp", &int_args));
        if (is_int) {
            const int_val = env.extractInteger(v);
            _ = c.sqlite3_bind_int64(stmt, param_idx, @intCast(int_val));
            continue;
        }

        var float_args = [_]emacs.Value{v};
        const is_float = env.isNotNil(try env.funcall("floatp", &float_args));
        if (is_float) {
            const float_val = env.extractFloat(v);
            _ = c.sqlite3_bind_double(stmt, param_idx, float_val);
            continue;
        }

        var str_args = [_]emacs.Value{v};
        const is_str = env.isNotNil(try env.funcall("stringp", &str_args));
        if (is_str) {
            const str_val = try env.extractString(allocator, v);
            _ = c.sqlite3_bind_text(stmt, param_idx, str_val.ptr, @intCast(str_val.len), c.SQLITE_STATIC);
            continue;
        }

        // Default to null
        _ = c.sqlite3_bind_null(stmt, param_idx);
    }
}

fn sqliteExecute(
    env: emacs.Env,
    db_val: emacs.Value,
    sql_val: emacs.Value,
    values_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };

    const sql = try env.extractString(context.gpa, sql_val);
    defer context.gpa.free(sql);

    // If no values provided, try fast path sqlite3_exec
    if (!env.isNotNil(values_val)) {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db.db.ptr, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            defer if (err_msg != null) c.sqlite3_free(err_msg);
            const msg = if (err_msg != null) std.mem.span(err_msg) else "unknown sqlite error";
            var err_args = [_]emacs.Value{
                env.makeString("sqlite execute error: %s"),
                env.makeString(msg),
            };
            _ = try env.funcall("error", &err_args);
            return env.nil;
        }
        const changes = c.sqlite3_changes64(db.db.ptr);
        return env.makeInteger(@intCast(changes));
    }

    // Parameterized path
    var arena = std.heap.ArenaAllocator.init(context.gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db.db.ptr, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        const errmsg = c.sqlite3_errmsg(db.db.ptr);
        const msg = if (errmsg != null) std.mem.span(errmsg) else "failed to prepare statement";
        var err_args = [_]emacs.Value{
            env.makeString("sqlite execute prepare error: %s"),
            env.makeString(msg),
        };
        _ = try env.funcall("error", &err_args);
        return env.nil;
    }
    defer _ = c.sqlite3_finalize(stmt);

    try bindValues(env, arena_allocator, stmt, values_val);

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
        const errmsg = c.sqlite3_errmsg(db.db.ptr);
        const msg = if (errmsg != null) std.mem.span(errmsg) else "sqlite execute step failed";
        var err_args = [_]emacs.Value{
            env.makeString("sqlite execute step error: %s"),
            env.makeString(msg),
        };
        _ = try env.funcall("error", &err_args);
        return env.nil;
    }

    const changes = c.sqlite3_changes64(db.db.ptr);
    return env.makeInteger(@intCast(changes));
}

fn sqliteExecuteBatch(env: emacs.Env, db_val: emacs.Value, sql_val: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };

    const sql = try env.extractString(context.gpa, sql_val);
    defer context.gpa.free(sql);

    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db.ptr, sql.ptr, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        const msg = if (err_msg != null) std.mem.span(err_msg) else "unknown sqlite error";
        var err_args = [_]emacs.Value{
            env.makeString("sqlite execute-batch error: %s"),
            env.makeString(msg),
        };
        _ = try env.funcall("error", &err_args);
        return env.nil;
    }
    return env.t;
}

fn sqliteSelect(
    env: emacs.Env,
    db_val: emacs.Value,
    sql_val: emacs.Value,
    values_val: emacs.Value,
    return_type_val: emacs.Value,
) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };

    const sql = try env.extractString(context.gpa, sql_val);
    defer context.gpa.free(sql);

    var arena = std.heap.ArenaAllocator.init(context.gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db.db.ptr, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) {
        const errmsg = c.sqlite3_errmsg(db.db.ptr);
        const msg = if (errmsg != null) std.mem.span(errmsg) else "failed to prepare query";
        var err_args = [_]emacs.Value{
            env.makeString("sqlite select prepare error: %s"),
            env.makeString(msg),
        };
        _ = try env.funcall("error", &err_args);
        return env.nil;
    }
    defer _ = c.sqlite3_finalize(stmt);

    try bindValues(env, arena_allocator, stmt, values_val);

    const col_count: usize = @intCast(c.sqlite3_column_count(stmt));

    // Check if return-type is 'full
    var is_full = false;
    if (env.isNotNil(return_type_val)) {
        if (env.eq(return_type_val, env.intern("full"))) {
            is_full = true;
        }
    }

    var rows = std.ArrayList(emacs.Value).empty;
    defer rows.deinit(context.gpa);

    while (true) {
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) break;
        if (step_rc != c.SQLITE_ROW) {
            const errmsg = c.sqlite3_errmsg(db.db.ptr);
            const msg = if (errmsg != null) std.mem.span(errmsg) else "sqlite step failed";
            var err_args = [_]emacs.Value{
                env.makeString("sqlite select step error: %s"),
                env.makeString(msg),
            };
            _ = try env.funcall("error", &err_args);
            return env.nil;
        }

        // Build row as an Emacs list
        var row_list = env.nil;
        var col_idx = col_count;
        while (col_idx > 0) {
            col_idx -= 1;
            const c_idx: c_int = @intCast(col_idx);
            const col_type = c.sqlite3_column_type(stmt, c_idx);
            const val: emacs.Value = switch (col_type) {
                c.SQLITE_INTEGER => env.makeInteger(c.sqlite3_column_int64(stmt, c_idx)),
                c.SQLITE_FLOAT => env.makeFloat(c.sqlite3_column_double(stmt, c_idx)),
                c.SQLITE_TEXT => blk: {
                    const text_ptr = c.sqlite3_column_text(stmt, c_idx);
                    const bytes_len = c.sqlite3_column_bytes(stmt, c_idx);
                    if (text_ptr == null or bytes_len <= 0) {
                        break :blk env.makeString("");
                    }
                    const text_slice = text_ptr[0..@intCast(bytes_len)];
                    const z_text = try context.gpa.allocSentinel(u8, text_slice.len, 0);
                    defer context.gpa.free(z_text);
                    @memcpy(z_text, text_slice);
                    break :blk env.makeString(z_text);
                },
                c.SQLITE_BLOB => blk: {
                    const blob_ptr = c.sqlite3_column_blob(stmt, c_idx);
                    const bytes_len = c.sqlite3_column_bytes(stmt, c_idx);
                    if (blob_ptr == null or bytes_len <= 0) {
                        break :blk env.makeUnibyteString("");
                    }
                    const raw_bytes: [*]const u8 = @ptrCast(blob_ptr);
                    break :blk env.makeUnibyteString(raw_bytes[0..@intCast(bytes_len)]);
                },
                c.SQLITE_NULL => env.nil,
                else => env.nil,
            };

            var cons_args = [_]emacs.Value{ val, row_list };
            row_list = try env.funcall("cons", &cons_args);
        }

        try rows.append(context.gpa, row_list);
    }

    var result_list = env.nil;
    if (rows.items.len > 0) {
        var idx = rows.items.len;
        while (idx > 0) {
            idx -= 1;
            var cons_args = [_]emacs.Value{ rows.items[idx], result_list };
            result_list = try env.funcall("cons", &cons_args);
        }
    }

    if (is_full) {
        var col_names_list = env.nil;
        var col_idx = col_count;
        while (col_idx > 0) {
            col_idx -= 1;
            const c_idx: c_int = @intCast(col_idx);
            const name_ptr = c.sqlite3_column_name(stmt, c_idx);
            const name_slice = if (name_ptr != null) std.mem.span(name_ptr) else "";
            const z_name = try context.gpa.allocSentinel(u8, name_slice.len, 0);
            defer context.gpa.free(z_name);
            @memcpy(z_name, name_slice);

            var cons_args = [_]emacs.Value{ env.makeString(z_name), col_names_list };
            col_names_list = try env.funcall("cons", &cons_args);
        }

        var full_cons_args = [_]emacs.Value{ col_names_list, result_list };
        result_list = try env.funcall("cons", &full_cons_args);
    }

    return result_list;
}

fn sqliteTransaction(env: emacs.Env, db_val: emacs.Value) !emacs.Value {
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db.ptr, "BEGIN;", null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        return env.reportError("sqlite transaction failed: ", error.TransactionFailed);
    }
    return env.t;
}

fn sqliteCommit(env: emacs.Env, db_val: emacs.Value) !emacs.Value {
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db.ptr, "COMMIT;", null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        return env.reportError("sqlite commit failed: ", error.CommitFailed);
    }
    return env.t;
}

fn sqliteRollback(env: emacs.Env, db_val: emacs.Value) !emacs.Value {
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db.ptr, "ROLLBACK;", null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        return env.reportError("sqlite rollback failed: ", error.RollbackFailed);
    }
    return env.t;
}

fn sqlitePragma(env: emacs.Env, db_val: emacs.Value, pragma_val: emacs.Value) !emacs.Value {
    const context = env.getUserData(ModuleContext) orelse return error.MissingModuleContext;
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };

    const pragma = try env.extractString(context.gpa, pragma_val);
    defer context.gpa.free(pragma);

    const sql = try std.fmt.allocPrintSentinel(context.gpa, "PRAGMA {s};", .{pragma}, 0);
    defer context.gpa.free(sql);

    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db.db.ptr, sql.ptr, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        return env.nil;
    }
    return env.t;
}

fn sqliteVersion(env: emacs.Env) emacs.Value {
    const ver = c.sqlite3_libversion();
    const ver_slice = if (ver != null) std.mem.span(ver) else "unknown";
    return env.makeString(ver_slice);
}

fn sqliteLastInsertRowId(env: emacs.Env, db_val: emacs.Value) !emacs.Value {
    const db = getValidDb(env, db_val) orelse {
        return env.reportError("invalid sqlite database pointer: ", error.InvalidDatabasePointer);
    };
    const rowid = c.sqlite3_last_insert_rowid(db.db.ptr);
    return env.makeInteger(@intCast(rowid));
}

// Backward-compatible wrappers for previous API
fn sqliteExecCompat(env: emacs.Env, db_val: emacs.Value, sql_val: emacs.Value) !emacs.Value {
    return sqliteExecute(env, db_val, sql_val, env.nil);
}

fn sqliteQueryCompat(env: emacs.Env, db_val: emacs.Value, sql_val: emacs.Value) !emacs.Value {
    return sqliteSelect(env, db_val, sql_val, env.nil, env.nil);
}

pub fn init(env: emacs.Env) c_int {
    env.makeFunction(
        "zig-sqlite-open",
        sqliteOpen,
        .{
            .doc_string = "Open FILE as an sqlite database (or nil for in-memory).",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-close",
        sqliteClose,
        .{
            .doc_string = "Close the sqlite database DB.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite--valid-p",
        sqliteP,
        .{
            .doc_string = "Return non-nil if OBJECT is a valid zig-sqlite database.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite--execute",
        sqliteExecute,
        .{
            .doc_string = "Internal execute with 3 arguments.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-execute-batch",
        sqliteExecuteBatch,
        .{
            .doc_string = "Execute multiple SQL statements in a single batch.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite--select",
        sqliteSelect,
        .{
            .doc_string = "Internal select with 4 arguments.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-transaction",
        sqliteTransaction,
        .{
            .doc_string = "Start a transaction in DB.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-commit",
        sqliteCommit,
        .{
            .doc_string = "Commit a transaction in DB.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-rollback",
        sqliteRollback,
        .{
            .doc_string = "Roll back a transaction in DB.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-pragma",
        sqlitePragma,
        .{
            .doc_string = "Execute PRAGMA in DB.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-version",
        sqliteVersion,
        .{
            .doc_string = "Return the SQLite library version string.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-last-insert-rowid",
        sqliteLastInsertRowId,
        .{
            .doc_string = "Return the rowid of the most recent successful INSERT.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    // Backward-compatibility aliases
    env.makeFunction(
        "zig-sqlite-exec",
        sqliteExecCompat,
        .{
            .doc_string = "Compatibility alias for zig-sqlite-execute without parameters.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    env.makeFunction(
        "zig-sqlite-query",
        sqliteQueryCompat,
        .{
            .doc_string = "Compatibility alias for zig-sqlite-select without parameters.",
            .user_data = @ptrCast(&module_context),
        },
    ) catch return 1;

    return 0;
}
