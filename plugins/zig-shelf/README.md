# zig-shelf

High-performance, concurrency-safe in-memory key-value store with native asynchronous channel streaming for GNU Emacs.

## Features

- **Lifecycle-managed handle**: Held via `makeUserPointer`, safe under Emacs GC.
- **Fast CRUD**: O(1) in-memory map protected with zero-overhead spinlock.
- **Asynchronous non-blocking streaming**: Background worker thread scans keys matching prefix and pipes items to Emacs `make-pipe-process` using native channel without freezing the UI.

## Usage

```elisp
(add-to-list 'load-path "/path/to/zig-emacs/zig-out/lib/")
(add-to-list 'load-path "/path/to/zig-emacs/plugins/zig-shelf/")
(load "libzig-shelf")
(require 'zig-shelf)

(with-zig-shelf shelf
  (zig-shelf-put shelf "article:1" "Introduction")
  (zig-shelf-put shelf "article:2" "Deep Dive")
  (message "Value: %s" (zig-shelf-get shelf "article:1"))
  (message "Count: %d" (zig-shelf-count shelf))

  ;; Asynchronous prefix scan without blocking Emacs UI
  (zig-shelf-scan shelf "article:"
                  (lambda (key val)
                    (message "Found: %s => %s" key val))
                  (lambda ()
                    (message "Scan finished!"))))
```
