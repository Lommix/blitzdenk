# Define the binary name
BINARY_NAME=blitzdenk

run:
	cargo run -- agent openai

# Build the project in release mode
release:
	cargo build --release

# Copy the binary to ~/.local/bin
install: release
	@cp target/release/$(BINARY_NAME) ~/.local/bin/
	@echo "Binary installed to ~/.local/bin/$(BINARY_NAME)"
