.PHONY: test test-rust conformance-rust test-bluespec

test: test-rust test-bluespec

test-rust:
	cargo test --manifest-path Cargo.toml --all-targets

conformance-rust:
	cargo run --quiet --manifest-path Cargo.toml -p naked-card --bin conformance

test-bluespec:
	bash scripts/test-bluespec.sh
