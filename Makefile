run:
	zig build run

install:
	# with debug!
	zig build
	cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	zig build test

gen:
	zig build gen
