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
                        (documentation 'zig-greeting))))

(defun generate-and-collect-garbage (count)
  (interactive "nNumber of lists to generate: ")
  (let (temp-lists)
    (dotimes (i count)
      (push (make-list 1000 (format "List %d" i)) temp-lists)))
  (garbage-collect))

(ert-deftest test-user-pointer ()
  (setq gc-cons-threshold 10
        gc-cons-threshold-message t)
  (dotimes (i 10)
    (let ((db (make-db i)))
      (should (save-text-to-db db (1+ i)))))
  (dotimes (i 10)
    (generate-and-collect-garbage 1000))
  )

;; ert-run-tests-batch
