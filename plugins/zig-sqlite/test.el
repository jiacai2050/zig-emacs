;;; -*- lexical-binding: t -*-

(require 'ert)

;; Load native module
(let ((module-dir (expand-file-name "../../zig-out/lib" (file-name-directory (or load-file-name buffer-file-name)))))
  (add-to-list 'load-path module-dir)
  (add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
  (load "libzig-sqlite"))

(require 'zig-sqlite)

(ert-deftest test-sqlite-meta ()
  (should (zig-sqlite-available-p))
  (should (stringp (zig-sqlite-version)))
  (should (> (length (zig-sqlite-version)) 0))
  (with-zig-sqlite (db)
    (should (zig-sqlite-p db))
    (should (null (zig-sqlite-p "not a db")))))

(ert-deftest test-sqlite-crud-and-params ()
  (with-zig-sqlite (db)
    ;; 1. Execute DDL
    (should (eq 0 (zig-sqlite-execute db "CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, salary REAL, manager TEXT);")))

    ;; 2. Parameterized execute
    (should (= 1 (zig-sqlite-execute db "INSERT INTO employees (name, salary, manager) VALUES (?, ?, ?);" '("Alice" 120.5 "Bob"))))
    (should (= 1 (zig-sqlite-last-insert-rowid db)))

    (should (= 1 (zig-sqlite-execute db "INSERT INTO employees (name, salary, manager) VALUES (?, ?, ?);" ["Bob" 200.0 nil])))
    (should (= 2 (zig-sqlite-last-insert-rowid db)))

    ;; 3. Parameterized select default (list of lists)
    (let ((rows (zig-sqlite-select db "SELECT id, name, salary, manager FROM employees WHERE salary > ? ORDER BY id ASC;" [100])))
      (should (= 2 (length rows)))
      (should (equal '(1 "Alice" 120.5 "Bob") (nth 0 rows)))
      (should (equal '(2 "Bob" 200.0 nil) (nth 1 rows))))

    ;; 4. Select with 'full (includes column names as first element)
    (let ((full-res (zig-sqlite-select db "SELECT name, salary FROM employees WHERE name = ?;" '("Alice") 'full)))
      (should (= 2 (length full-res)))
      (should (equal '("name" "salary") (car full-res)))
      (should (equal '("Alice" 120.5) (cadr full-res))))

    ;; 5. Update with parameters
    (should (= 1 (zig-sqlite-execute db "UPDATE employees SET salary = ? WHERE name = ?;" [150.0 "Alice"])))
    (let ((rows (zig-sqlite-select db "SELECT salary FROM employees WHERE name = ?;" '("Alice"))))
      (should (equal '((150.0)) rows)))

    ;; 6. Delete
    (should (= 1 (zig-sqlite-execute db "DELETE FROM employees WHERE name = ?;" '("Bob"))))
    (let ((rows (zig-sqlite-select db "SELECT count(*) FROM employees;")))
      (should (equal '((1)) rows)))))

(ert-deftest test-sqlite-execute-batch ()
  (with-zig-sqlite (db)
    (should (zig-sqlite-execute-batch db "
CREATE TABLE t1 (v TEXT);
CREATE TABLE t2 (v TEXT);
INSERT INTO t1 VALUES ('one');
INSERT INTO t2 VALUES ('two');
"))
    (should (equal '(("one")) (zig-sqlite-select db "SELECT v FROM t1;")))
    (should (equal '(("two")) (zig-sqlite-select db "SELECT v FROM t2;")))))

(ert-deftest test-sqlite-transactions ()
  (with-zig-sqlite (db)
    (zig-sqlite-execute db "CREATE TABLE bank (acc TEXT PRIMARY KEY, bal INT);")

    ;; with-zig-sqlite-transaction success
    (with-zig-sqlite-transaction db
      (zig-sqlite-execute db "INSERT INTO bank VALUES (?, ?);" '("A" 500))
      (zig-sqlite-execute db "INSERT INTO bank VALUES (?, ?);" '("B" 300)))

    (should (equal '((2)) (zig-sqlite-select db "SELECT count(*) FROM bank;")))

    ;; with-zig-sqlite-transaction rollback
    (ignore-errors
      (with-zig-sqlite-transaction db
        (zig-sqlite-execute db "INSERT INTO bank VALUES (?, ?);" '("C" 100))
        (error "Forced failure for rollback")))

    (should (equal '((2)) (zig-sqlite-select db "SELECT count(*) FROM bank;")))

    ;; Explicit transaction / commit / rollback
    (zig-sqlite-transaction db)
    (zig-sqlite-execute db "INSERT INTO bank VALUES ('D', 400);")
    (zig-sqlite-commit db)
    (should (equal '((3)) (zig-sqlite-select db "SELECT count(*) FROM bank;")))

    (zig-sqlite-transaction db)
    (zig-sqlite-execute db "INSERT INTO bank VALUES ('E', 999);")
    (zig-sqlite-rollback db)
    (should (equal '((3)) (zig-sqlite-select db "SELECT count(*) FROM bank;")))))

(ert-deftest test-sqlite-pragma ()
  (with-zig-sqlite (db)
    (should (zig-sqlite-pragma db "user_version = 42"))
    (let ((res (zig-sqlite-select db "PRAGMA user_version;")))
      (should (equal '((42)) res)))))

(ert-deftest test-sqlite-file-persistence ()
  (let ((db-path (expand-file-name "zig-out/test_aligned.sqlite" default-directory)))
    (when (file-exists-p db-path)
      (delete-file db-path))

    (with-zig-sqlite (db db-path)
      (zig-sqlite-execute db "CREATE TABLE store (k TEXT PRIMARY KEY, v TEXT);")
      (zig-sqlite-execute db "INSERT INTO store VALUES (?, ?);" '("hello" "emacs")))

    (with-zig-sqlite (db db-path)
      (should (equal '(("emacs")) (zig-sqlite-select db "SELECT v FROM store WHERE k = ?;" '("hello")))))

    (when (file-exists-p db-path)
      (delete-file db-path))))
