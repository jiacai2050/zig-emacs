;;; zig-sqlite.el --- Embedded SQLite engine aligned with builtin Emacs SQLite -*- lexical-binding: t; -*-

;;; Commentary:
;; Fast, embedded SQLite dynamic module for GNU Emacs aligned with official Emacs 29+ sqlite.el APIs.

;;; Code:

(require 'subr-x)

(defgroup zig-sqlite nil
  "Embedded SQLite database powered by Zig."
  :group 'data
  :prefix "zig-sqlite-")

(defun zig-sqlite-available-p ()
  "Return non-nil if zig-sqlite support is available."
  t)

(defun zig-sqlite-p (object)
  "Return non-nil if OBJECT is a valid zig-sqlite database."
  (and (user-ptrp object)
       (zig-sqlite--valid-p object)))

(defun zig-sqlite-execute (db sql &optional values)
  "Execute a non-select SQL statement on DB with optional parameter VALUES.
VALUES can be a list or vector. Returns number of affected rows."
  (zig-sqlite--execute db sql values))

(defun zig-sqlite-select (db sql &optional values return-type)
  "Select data matching SQL from DB, with optional VALUES and RETURN-TYPE.
If RETURN-TYPE is \\='full, the first row contains column names."
  (zig-sqlite--select db sql values return-type))

;; Backward compatibility aliases
(defalias 'zig-sqlite-exec #'zig-sqlite-execute)
(defalias 'zig-sqlite-query #'zig-sqlite-select)

(defmacro with-zig-sqlite (spec &rest body)
  "Open a SQLite database and execute BODY, ensuring it is closed.
SPEC is either (VAR) for an in-memory database or (VAR PATH) for a file database."
  (declare (indent 1))
  (let ((var (if (listp spec) (car spec) spec))
        (path (if (and (listp spec) (cdr spec)) (cadr spec) nil)))
    `(let ((,var (zig-sqlite-open ,path)))
       (unwind-protect
           (progn ,@body)
         (when ,var
           (zig-sqlite-close ,var))))))

(defmacro with-zig-sqlite-transaction (db &rest body)
  "Execute BODY with an active transaction on DB, committing on success and rolling back on error."
  (declare (indent 1))
  `(progn
     (zig-sqlite-transaction ,db)
     (condition-case err
         (let ((result (progn ,@body)))
           (zig-sqlite-commit ,db)
           result)
       (error
        (zig-sqlite-rollback ,db)
        (signal (car err) (cdr err))))))

;; Backward-compatibility alias
(defalias 'zig-sqlite-transaction-macro 'with-zig-sqlite-transaction)

(defun zig-sqlite-enable-as-builtin ()
  "Register zig-sqlite functions as official sqlite-* functions when not natively available."
  (interactive)
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (defalias 'sqlite-available-p #'zig-sqlite-available-p)
    (defalias 'sqlitep #'zig-sqlite-p)
    (defalias 'sqlite-open #'zig-sqlite-open)
    (defalias 'sqlite-close #'zig-sqlite-close)
    (defalias 'sqlite-execute #'zig-sqlite-execute)
    (defalias 'sqlite-execute-batch #'zig-sqlite-execute-batch)
    (defalias 'sqlite-select #'zig-sqlite-select)
    (defalias 'sqlite-transaction #'zig-sqlite-transaction)
    (defalias 'sqlite-commit #'zig-sqlite-commit)
    (defalias 'sqlite-rollback #'zig-sqlite-rollback)
    (defalias 'with-sqlite-transaction #'with-zig-sqlite-transaction)
    (defalias 'sqlite-pragma #'zig-sqlite-pragma)
    (defalias 'sqlite-version #'zig-sqlite-version)
    (message "zig-sqlite has been registered as builtin sqlite.")))

(provide 'zig-sqlite)
;;; zig-sqlite.el ends here
