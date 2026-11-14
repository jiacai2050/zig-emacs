# zig-fuzzy

High-performance fuzzy matching and sorting for GNU Emacs, implemented as a Zig dynamic module.

## Features

- **Subsequence matching** with intelligent scoring (prefix bonuses, word boundaries, camelCase transitions).
- **Smart-case**: Case-insensitive if query is all lower-case, case-sensitive if query contains upper-case characters.
- **Fast sorting**: Vector and list support with low allocation overhead.

## Usage

```elisp
(add-to-list 'load-path "/path/to/zig-emacs/zig-out/lib/")
(add-to-list 'load-path "/path/to/zig-emacs/plugins/zig-fuzzy/")
(load "libzig-fuzzy")
(require 'zig-fuzzy)

;; Fuzzy score
(zig-fuzzy-score "src/root.zig" "root") ; => integer score or nil

;; Filter candidates
(zig-fuzzy-match '("src/root.zig" "example.zig" "build.zig") "zig")
; => ("build.zig" "example.zig" "src/root.zig")
```
