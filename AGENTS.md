## Build, Lint, Test Commands

- Use `cargo build` for building the project.
- Run `cargo test` to run all tests.
- To run a single test, use `cargo test <test_name>`.
- Run linting and type checking with `cargo clippy` and `cargo check`.

## Code Style Guidelines

- Imports grouped by extern crates first, then internal modules.
- Use Rust 2024 edition idioms and async/await.
- Naming conventions: snake_case for functions and variables, PascalCase for types.
- Error handling uses the `thiserror` crate with custom error types.
- Avoid adding comments unless requested.
- Write concise, direct code adhering to existing patterns.

## Formatting

- Use rustfmt with default settings.
- Maintain consistent indentation (4 spaces) and line length (100).

## Error Handling

- Standardize on AiError enum for error results.
- Use `Result<T, AiError>` alias for function return types.
- Convert external crate errors using `From` trait implementations.
