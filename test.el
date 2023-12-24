;;; -*- lexical-binding: t -*-

(progn
  (require 'ert)
  (add-to-list 'load-path (expand-file-name "zig-out/lib/"))
  (load "libzig-example"))

(ert-deftest test-zig-add ()
  (should (eq 2 (zig-add 1 1)))
  (should (eq 1100 (zig-add 100 1000)))
  (should (commandp 'zig-add))
  (should (null (documentation 'zig-add)))
  )

(ert-deftest test-zig-greeting ()
  (should (string-equal "hello Jiacai!" (zig-greeting "Jiacai")))
  (should (not (commandp 'zig-greeting)))
  (should (string-equal "greeting written in Zig"
                        (documentation 'zig-greeting)))
  )

(ert-deftest test-user-pointer ()
  (setq gc-cons-threshold 100
        gc-cons-threshold-message t)
  (dotimes (i 10)
    (let ((db (make-db 123)))
      (should (save-text-to-db db 456)))
    (let ((lst '()))
      (dotimes (j 100)
        (push 'a lst))
      (garbage-collect)))
  )
