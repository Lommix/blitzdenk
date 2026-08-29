install:
	@zig build --release=small
	@rm -f ~/.local/bin/blitz
	@cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	@echo "===blitzdenk tests==="
	@zig build test --summary all --error-style minimal
	@echo "===sdk tests==="
	@cd sdk && zig build test --summary all --error-style minimal

gen:
	@zig build gen
	@echo "===generated lua bindings==="
