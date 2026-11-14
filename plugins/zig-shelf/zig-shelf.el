;;; zig-shelf.el --- Asynchronous key-value store powered by Zig -*- lexical-binding: t; -*-

;;; Commentary:
;; Fast key-value store with native async channel streaming for GNU Emacs.

;;; Code:

(require 'subr-x)

(defgroup zig-shelf nil
  "Asynchronous key-value store powered by Zig."
  :group 'data
  :prefix "zig-shelf-")

(defmacro with-zig-shelf (var &rest body)
  "Open a temporary shelf bound to VAR and execute BODY, ensuring it is closed."
  (declare (indent 1))
  `(let ((,var (zig-shelf-open)))
     (unwind-protect
         (progn ,@body)
       (when ,var
         (zig-shelf-close ,var)))))

(defun zig-shelf-scan (shelf prefix on-item &optional on-done)
  "Scan SHELF for keys matching PREFIX asynchronously.
For each matched key-value pair, ON-ITEM is called with (key value).
When the scan finishes, ON-DONE is called with no arguments.
Returns the pipe process."
  (let* ((pending-output "")
         (pipe-proc nil))
    (setq pipe-proc
          (make-pipe-process
           :name "zig-shelf-scan-pipe"
           :buffer nil
           :noquery t
           :filter
           (lambda (proc string)
             (setq pending-output (concat pending-output string))
             (while (string-match "\\([^\n]*\\)\n" pending-output)
               (let ((line (match-string 1 pending-output)))
                 (setq pending-output (substring pending-output (match-end 0)))
                 (if (string-equal "__SHELF_DONE__" line)
                     (progn
                       (delete-process proc)
                       (when on-done (funcall on-done)))
                   (let ((tab-pos (string-match "\t" line)))
                     (when tab-pos
                       (let ((key (substring line 0 tab-pos))
                             (val (substring line (1+ tab-pos))))
                         (funcall on-item key val))))))))
           :sentinel
           (lambda (proc _event)
             (when (and (not (process-live-p proc)) on-done)
               (funcall on-done)))))
    (zig-shelf-scan-async shelf prefix pipe-proc)
    pipe-proc))

(provide 'zig-shelf)
;;; zig-shelf.el ends here
