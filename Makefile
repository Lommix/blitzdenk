run:
	zig build run

install:
	# with debug!
	zig build
	cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	@zig build test --summary all --error-style minimal

gen:
	zig build gen
