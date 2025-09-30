
build:
	zig build --summary all

build-release:
	zig build --summary all -Doptimize=ReleaseSafe

clean:
	rm -rf .zig-cache zig-out

test: build
	emacs -Q -batch -l test.el -f ert-run-tests-batch-and-exit

lint:
	zig fmt --check .

docs:
	zig build docs

.PHONY: build build-release clean lint test docs
