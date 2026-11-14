# zig-sqlite

High-performance embedded SQLite engine for GNU Emacs, natively aligned with the official Emacs 29+ `sqlite.el` API and powered by [zig-sqlite](https://github.com/nDimensional/zig-sqlite).

## Why zig-sqlite?

| Feature | Emacs Builtin (`sqlite.c`) | zig-sqlite |
|---|---|---|
| **Host System Dependency** | Requires host `libsqlite3` and `--with-sqlite3` build flag | **Zero Dependency**: Statically compiles SQLite amalgamation into the module artifact |
| **Emacs Compatibility** | Requires **Emacs 29.1+** | **Emacs 28+**: Drop-in compatible polyfill via `(zig-sqlite-enable-as-builtin)` |
| **Parameter Binding** | Allocates or copies across C boundary | **Zero-Copy**: Arena-managed lifetime with `SQLITE_STATIC` zero-copy bindings |
| **Execution Model** | Main-thread blocking only | Extensible with native threads & `openChannel` non-blocking streaming |
| **Compilation Footprint** | Recompilation of whole Emacs required | Standalone module (~2MB artifact, compiles in seconds via `zig build`) |

### Key Highlights

1. **Zero Host Dependencies (Self-Contained)**:
   Many Emacs builds (especially minimal distributions, Docker containers, Termux, or older OS versions) are built without `--with-sqlite3`. `zig-sqlite` bundles the official `sqlite-amalgamation` source directly, requiring no external SQLite shared libraries.
2. **Official API Polyfill for Emacs 28+**:
   Full parity with Emacs 29+ official function signatures (`sqlite-open`, `sqlite-execute`, `sqlite-select`, `with-sqlite-transaction`, etc.). Calling `(zig-sqlite-enable-as-builtin)` allows packages targeting Emacs 29+ SQLite (such as modern Org-roam or multisession) to run on Emacs 28 without modifying their codebase.
3. **High-Performance Memory Model**:
   Query parameters are extracted using an `ArenaAllocator` scoped strictly to the query lifecycle, passing `SQLITE_STATIC` directly to SQLite. This eliminates secondary memory copies and heap fragmentation.

## Features

- **Builtin SQLite Alignment**: Drop-in compatible APIs matching Emacs 29+ builtin `sqlite-*` functions (`sqlite-open`, `sqlite-execute`, `sqlite-select`, `with-sqlite-transaction`, etc.).
- **Official Polyfill**: Seamlessly register as official builtins via `(zig-sqlite-enable-as-builtin)`.
- **Parameterized Queries (`?`)**: Full protection against SQL injection with automatic binding for integers, floats, strings, blobs, and nulls.
- **Both In-Memory & Persistent**: Supports `:memory:` as well as file-based `.sqlite` databases.

## Build

`zig-sqlite` is configured as a lazy dependency. To build it, enable the `-Denable-sqlite` flag:

```bash
zig build -Denable-sqlite=true
# Or via Makefile:
make build-all
```

## Usage

```elisp
(add-to-list 'load-path "/path/to/zig-emacs/zig-out/lib/")
(add-to-list 'load-path "/path/to/zig-emacs/plugins/zig-sqlite/")
(load "libzig-sqlite")
(require 'zig-sqlite)

;; 1. In-memory database with parameterized statements
(with-zig-sqlite (db)
  ;; DDL
  (zig-sqlite-execute db "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL);")

  ;; Parameterized INSERT (prevents SQL injection)
  (zig-sqlite-execute db "INSERT INTO users (name, score) VALUES (?, ?);" '("Alice" 98.5))
  (zig-sqlite-execute db "INSERT INTO users (name, score) VALUES (?, ?);" ["Bob" 82.0])

  ;; Parameterized SELECT matching official return format: '((1 "Alice" 98.5))
  (message "Result: %S"
           (zig-sqlite-select db "SELECT id, name, score FROM users WHERE score > ?;" [90]))

  ;; SELECT with 'full to include column names as first element
  (message "Full: %S"
           (zig-sqlite-select db "SELECT name, score FROM users;" nil 'full)))
  ;; => (("name" "score") ("Alice" 98.5) ("Bob" 82.0))

;; 2. Automatic transaction handling
(with-zig-sqlite (db)
  (zig-sqlite-execute db "CREATE TABLE accounts (name TEXT, balance INT);")
  (with-zig-sqlite-transaction db
    (zig-sqlite-execute db "INSERT INTO accounts VALUES (?, ?);" '("Alice" 500))
    (zig-sqlite-execute db "INSERT INTO accounts VALUES (?, ?);" '("Bob" 300))))

;; 3. Batch execution
(with-zig-sqlite (db)
  (zig-sqlite-execute-batch db "
    CREATE TABLE t1 (v TEXT);
    CREATE TABLE t2 (v TEXT);
    INSERT INTO t1 VALUES ('one');
  "))

;; 4. Polyfill: enable as official builtin sqlite in Emacs
(zig-sqlite-enable-as-builtin)
;; Now sqlite-open, sqlite-execute, sqlite-select etc. work anywhere!
```
