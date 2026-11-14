;;; zig-fuzzy.el --- High performance fuzzy matching via Zig -*- lexical-binding: t; -*-

;;; Commentary:
;; Fast fuzzy matching and sorting powered by a Zig dynamic module.

;;; Code:

(require 'subr-x)

(defgroup zig-fuzzy nil
  "High performance fuzzy matching via Zig."
  :group 'convenience
  :prefix "zig-fuzzy-")

(defun zig-fuzzy-match (candidates query &optional limit as-vector)
  "Match CANDIDATES against QUERY and return sorted matches.
CANDIDATES can be a list or a vector of strings.
If LIMIT is non-nil, return at most LIMIT matches.
If AS-VECTOR is non-nil, return a vector instead of a list."
  (let* ((vec (if (vectorp candidates)
                  candidates
                (vconcat candidates)))
         (matched-vec (zig-fuzzy-match-vector vec query limit)))
    (if as-vector
        matched-vec
      (append matched-vec nil))))

(defun zig-fuzzy-completing-read (prompt collection &optional predicate require-match initial-input hist def inherit-input-method)
  "Read string in minibuffer with `zig-fuzzy' sorting as prompt."
  (let ((candidates (if (functionp collection)
                        (funcall collection "" predicate t)
                      collection)))
    (completing-read prompt
                     (lambda (string pred action)
                       (if (eq action 'metadata)
                           '(metadata (display-sort-function . identity)
                                      (cycle-sort-function . identity))
                         (complete-with-action action candidates string pred)))
                     predicate require-match initial-input hist def inherit-input-method)))

(provide 'zig-fuzzy)
;;; zig-fuzzy.el ends here
