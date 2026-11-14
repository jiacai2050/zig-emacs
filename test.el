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

(ert-deftest test-predicates ()
  ;; Items order: (isNil isInteger isFloat isNumber isString isSymbol isVector isUserPointer isCons isList)
  ;; 1. nil
  (should (equal '(t nil nil nil nil t nil nil nil t) (zig-test-predicates nil)))
  ;; 2. integer
  (should (equal '(nil t nil t nil nil nil nil nil nil) (zig-test-predicates 42)))
  ;; 3. float
  (should (equal '(nil nil t t nil nil nil nil nil nil) (zig-test-predicates 3.14)))
  ;; 4. string
  (should (equal '(nil nil nil nil t nil nil nil nil nil) (zig-test-predicates "hello")))
  ;; 5. symbol
  (should (equal '(nil nil nil nil nil t nil nil nil nil) (zig-test-predicates 'foo)))
  ;; 6. vector
  (should (equal '(nil nil nil nil nil nil t nil nil nil) (zig-test-predicates [1 2 3])))
  ;; 7. user pointer
  (let ((db (make-db 1)))
    (should (equal '(nil nil nil nil nil nil nil t nil nil) (zig-test-predicates db))))
  ;; 8. cons / list
  (should (equal '(nil nil nil nil nil nil nil nil t t) (zig-test-predicates '(1 2 3)))))

(ert-deftest test-list-ops ()
  (let ((res (zig-test-list-ops '(1 2 3 4))))
    (should (= 4 (nth 0 res)))
    (should (equal '(4 3 2 1) (nth 1 res))))
  (let ((res (zig-test-list-ops nil)))
    (should (= 0 (nth 0 res)))
    (should (null (nth 1 res)))))

(ert-deftest test-type-enum ()
  (should (string-equal "nil" (zig-test-type-enum nil)))
  (should (string-equal "integer" (zig-test-type-enum 100)))
  (should (string-equal "float" (zig-test-type-enum 2.718)))
  (should (string-equal "string" (zig-test-type-enum "zig-emacs")))
  (should (string-equal "symbol" (zig-test-type-enum 'my-symbol)))
  (should (string-equal "vector" (zig-test-type-enum [10 20])))
  (should (string-equal "cons" (zig-test-type-enum '(a . b))))
  (let ((db (make-db 99)))
    (should (string-equal "user_ptr" (zig-test-type-enum db)))))

(ert-deftest test-sequence ()
  ;; Sequence accepts both List and Vector, returns Vector
  (should (equal [1 2 3] (zig-test-sequence '(1 2 3))))
  (should (equal [10 20 30] (zig-test-sequence [10 20 30])))
  (should (equal [] (zig-test-sequence nil)))
  (should (equal [] (zig-test-sequence [])))
  ;; Non-sequence returns nil
  (should (null (zig-test-sequence 1234))))

;; ert-run-tests-batch
