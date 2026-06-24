run:
	zig build run

install:
	zig build --release=small
	cp zig-out/bin/blitz ~/.local/bin/blitz

test:
	zig build test

upgrade: install
	cp src/blitz_defs.lua ~/.config/blitzdenk/meta.lua

gen:
	zig build gen
