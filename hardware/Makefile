.PHONY: test test-rust conformance-rust test-bluespec test-qic-phase4-6

test: test-rust test-bluespec

test-rust:
	cargo test --manifest-path Cargo.toml --all-targets

conformance-rust:
	cargo run --quiet --manifest-path Cargo.toml -p naked-card --bin conformance

test-bluespec:
	bash scripts/test-bluespec.sh
	bash scripts/test-qic-phase4-6.sh

test-qic-phase4-6:
	bash scripts/test-qic-phase4-6.sh
