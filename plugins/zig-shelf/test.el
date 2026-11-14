;;; -*- lexical-binding: t -*-

(require 'ert)

;; Load native module
(let ((module-dir (expand-file-name "../../zig-out/lib" (file-name-directory (or load-file-name buffer-file-name)))))
  (add-to-list 'load-path module-dir)
  (add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
  (load "libzig-shelf"))

(require 'zig-shelf)

(ert-deftest test-shelf-crud ()
  (with-zig-shelf shelf
    (should (eq 0 (zig-shelf-count shelf)))
    (zig-shelf-put shelf "user:1" "Alice")
    (zig-shelf-put shelf "user:2" "Bob")
    (zig-shelf-put shelf "org:deepmind" "London")
    (should (eq 3 (zig-shelf-count shelf)))

    ;; Get existing keys
    (should (string-equal "Alice" (zig-shelf-get shelf "user:1")))
    (should (string-equal "Bob" (zig-shelf-get shelf "user:2")))
    ;; Non-existing key returns nil
    (should (null (zig-shelf-get shelf "nonexistent")))

    ;; Delete
    (should (zig-shelf-delete shelf "user:2"))
    (should (null (zig-shelf-delete shelf "user:2")))
    (should (eq 2 (zig-shelf-count shelf)))))

(ert-deftest test-shelf-async-scan ()
  (with-zig-shelf shelf
    (dotimes (i 50)
      (zig-shelf-put shelf (format "prefix:key:%02d" i) (format "value:%d" i)))
    (zig-shelf-put shelf "other:1" "foo")
    (zig-shelf-put shelf "other:2" "bar")

    (let ((collected '())
          (done nil)
          proc)
      (setq proc
            (zig-shelf-scan shelf "prefix:"
                            (lambda (k v)
                              (push (cons k v) collected))
                            (lambda ()
                              (setq done t))))

      ;; Wait for async channel to complete
      (with-timeout (5 (error "Scan timed out"))
        (while (and (not done) (process-live-p proc))
          (accept-process-output proc 0.05)))

      (should (= 50 (length collected)))
      (should done))))
