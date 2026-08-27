install:
	@zig build --release=small
	@rm -f ~/.local/bin/blitz
	@cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	@zig build test --summary all --error-style minimal

gen:
	@zig build gen
