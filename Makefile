install:
	@zig build --release=small
	@rm -f ~/.local/bin/blitz
	@cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	@echo "===blitzdenk tests==="
	@zig build test --summary all --error-style minimal
	@echo "===sdk tests==="
	@cd blitz-sdk && zig build test --summary all --error-style minimal

check:
	@echo "===format==="
	@zig fmt --check src build.zig blitz-sdk
	@echo "===generated meta==="
	@set -e; tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	cp src/meta.lua "$$tmp"; \
	zig build gen; \
	if ! cmp -s src/meta.lua "$$tmp"; then \
		echo "src/meta.lua was stale; regenerated. Commit the result."; \
		exit 1; \
	fi
	@$(MAKE) test

gen:
	@zig build gen
	@echo "===generated lua bindings==="
