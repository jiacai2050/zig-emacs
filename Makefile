
build:
	zig build --summary all

build-all:
	zig build -Denable-sqlite=true --summary all

build-release:
	zig build --summary all -Doptimize=ReleaseSafe

clean:
	rm -rf .zig-cache zig-out

test: test-example test-fuzzy test-shelf test-sqlite test-unit

test-example: build
	emacs -Q -batch -l test.el -f ert-run-tests-batch-and-exit

test-fuzzy: build
	emacs -Q -batch -l plugins/zig-fuzzy/test.el -f ert-run-tests-batch-and-exit

test-shelf: build
	emacs -Q -batch -l plugins/zig-shelf/test.el -f ert-run-tests-batch-and-exit

test-sqlite:
	zig build -Denable-sqlite=true --summary all
	emacs -Q -batch -l plugins/zig-sqlite/test.el -f ert-run-tests-batch-and-exit

test-unit:
	zig build test-unit

lint:
	zig fmt --check .

docs:
	zig build docs

.PHONY: build build-all build-release clean lint test test-example test-fuzzy test-shelf test-sqlite test-unit docs
