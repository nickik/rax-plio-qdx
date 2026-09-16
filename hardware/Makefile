.PHONY: test test-rust conformance-rust test-bluespec test-bluespec-core test-qic-phase4-6 test-qic-phase7-9 test-memory-controller test-memory-controller-all test-memory-controller-semantics test-memory-controller-bram test-mainboard-fpga

test: test-rust test-bluespec

test-rust:
	cargo test --manifest-path Cargo.toml --all-targets

conformance-rust:
	cargo run --quiet --manifest-path Cargo.toml -p naked-card --bin conformance

# Aggregate local gate. CI calls the component targets independently so these
# expensive suites can run in parallel and are not executed twice.
test-bluespec: test-bluespec-core test-memory-controller test-mainboard-fpga

test-bluespec-core:
	bash scripts/test-bluespec.sh
	bash scripts/test-qic-phase4-6.sh
	bash scripts/test-qic-phase7.sh
	bash scripts/test-qic-phase8.sh
	bash scripts/test-qic-phase9.sh

test-qic-phase4-6:
	bash scripts/test-qic-phase4-6.sh

test-qic-phase7-9:
	bash scripts/test-qic-phase7.sh
	bash scripts/test-qic-phase8.sh
	bash scripts/test-qic-phase9.sh

test-memory-controller:
	bash scripts/test-memory-controller.sh

test-memory-controller-all:
	bash scripts/test-memory-controller.sh
	bash scripts/test-memory-controller-backend.sh
	bash scripts/test-memory-controller-semantics.sh
	bash scripts/test-memory-controller-bram.sh

test-memory-controller-semantics:
	bash scripts/test-memory-controller-semantics.sh

test-memory-controller-bram:
	bash scripts/test-memory-controller-bram.sh

test-mainboard-fpga:
	$(MAKE) -C mainboard-fpga test
