;;; -*- lexical-binding: t -*-

(require 'ert)

;; Load native module
(let ((module-dir (expand-file-name "../../zig-out/lib" (file-name-directory (or load-file-name buffer-file-name)))))
  (add-to-list 'load-path module-dir)
  (add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
  (load "libzig-fuzzy"))

(require 'zig-fuzzy)

(ert-deftest test-fuzzy-score ()
  (should (integerp (zig-fuzzy-score "src/root.zig" "root")))
  (should (null (zig-fuzzy-score "src/root.zig" "xyz")))
  ;; Prefix and boundary match should score higher than mid-word match
  (let ((score1 (zig-fuzzy-score "src/root.zig" "src"))
        (score2 (zig-fuzzy-score "src/root.zig" "oot")))
    (should (> score1 score2))))

(ert-deftest test-fuzzy-match ()
  (let ((candidates '("src/root.zig"
                      "example.zig"
                      "build.zig"
                      "include/emacs-module.h"
                      "README.org")))
    ;; Match .zig files
    (let ((res (zig-fuzzy-match candidates "zig")))
      (should (= 3 (length res)))
      (should (member "src/root.zig" res))
      (should (member "example.zig" res))
      (should (member "build.zig" res)))

    ;; Limit test
    (let ((res (zig-fuzzy-match candidates "zig" 2)))
      (should (= 2 (length res))))

    ;; Boundary ranking: "bz" should rank "build.zig" at top
    (let ((res (zig-fuzzy-match candidates "bz")))
      (should (string-equal "build.zig" (car res))))))
