;;; -*- lexical-binding: t -*-

(require 'ert)

(add-to-list 'load-path (expand-file-name "zig-out/lib/"))

(load "libzig-example")

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
