run:
	zig build run

install:
	zig build --release=small
	cp zig-out/bin/blitzcloud ~/.local/bin/blitz

test:
	zig build test
