.PHONY: test test-rust conformance-rust test-bluespec test-qic-phase4-6 test-qic-phase7-9 test-memory-controller

test: test-rust test-bluespec

test-rust:
	cargo test --manifest-path Cargo.toml --all-targets

conformance-rust:
	cargo run --quiet --manifest-path Cargo.toml -p naked-card --bin conformance

test-bluespec:
	bash scripts/test-bluespec.sh
	bash scripts/test-qic-phase4-6.sh
	bash scripts/test-qic-phase7.sh
	bash scripts/test-qic-phase8.sh
	bash scripts/test-qic-phase9.sh
	bash scripts/test-memory-controller.sh

test-qic-phase4-6:
	bash scripts/test-qic-phase4-6.sh

test-qic-phase7-9:
	bash scripts/test-qic-phase7.sh
	bash scripts/test-qic-phase8.sh
	bash scripts/test-qic-phase9.sh

test-memory-controller:
	bash scripts/test-memory-controller.sh
