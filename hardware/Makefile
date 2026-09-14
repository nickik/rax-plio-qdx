.PHONY: test-rust conformance-rust

test-rust:
	cargo test --manifest-path Cargo.toml --all-targets

conformance-rust:
	cargo run --quiet --manifest-path Cargo.toml -p naked-card --bin conformance

# Bluespec targets are added after the QLI v0.1 Rust semantics are frozen.
