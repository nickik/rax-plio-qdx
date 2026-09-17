SHELL := /bin/bash
BSC ?= bsc
YOSYS ?= yosys
ROOT := $(abspath ..)
BUILD := $(abspath build)
BASE_SEARCH := +:$(ROOT)/qli/bluespec:$(ROOT)/qic/bluespec:$(ROOT)/pti/bluespec:$(ROOT)/plio-tx/bluespec:$(ROOT)/plio-rax-host/bluespec:$(ROOT)/memory-controller/bluespec:$(abspath bluespec)
QDXB_SEARCH := $(BASE_SEARCH):$(ROOT)/qli16/bluespec:$(ROOT)/testbench/bluespec:$(ROOT)/qdx-a/bluespec:$(ROOT)/qdx-b/bluespec:$(ROOT)/qdx-b-card/bluespec

.PHONY: test test-isolated test-memory-semantics test-byte-enable test-cpu-grant test-cpu-write test-cpu-read test-reset-recovery test-plio-dma test-lifecycle-coverage test-core test-qdx-b test-lighting-plio0 test-lighting-plio0-dma-csr verilog-sanity clean

test: test-isolated test-core test-qdx-b test-lighting-plio0 verilog-sanity

test-isolated: test-memory-semantics test-byte-enable test-cpu-grant test-cpu-write test-cpu-read test-reset-recovery test-plio-dma test-lifecycle-coverage test-lighting-plio0-dma-csr

test-lighting-plio0-dma-csr:
	rm -rf $(BUILD)/lighting-plio0-dma-csr
	mkdir -p $(BUILD)/lighting-plio0-dma-csr
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/lighting-plio0-dma-csr -simdir $(BUILD)/lighting-plio0-dma-csr -info-dir $(BUILD)/lighting-plio0-dma-csr \
		-g mkTbMainboardLightingPlio0DmaCsr bluespec/TbMainboardLightingPlio0DmaCsr.bsv 2>&1 | tee $(BUILD)/lighting-plio0-dma-csr/compile.log
	@if grep -q '(G0023)' $(BUILD)/lighting-plio0-dma-csr/compile.log; then \
		echo 'FAIL Lighting PLIO0 DMA CSR test contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/lighting-plio0-dma-csr -simdir $(BUILD)/lighting-plio0-dma-csr \
		-e mkTbMainboardLightingPlio0DmaCsr -o $(BUILD)/lighting-plio0-dma-csr/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/lighting-plio0-dma-csr/tb 2>&1 | tee $(BUILD)/lighting-plio0-dma-csr/run.log; \
	else \
		set -o pipefail; $(BUILD)/lighting-plio0-dma-csr/tb 2>&1 | tee $(BUILD)/lighting-plio0-dma-csr/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/lighting-plio0-dma-csr/run.log; then exit 1; fi
	@grep -Fq 'PASS|lighting-plio0-dma-csr|CPU programs frozen DMA table through Mainboard host state' $(BUILD)/lighting-plio0-dma-csr/run.log

test-memory-semantics:
	rm -rf $(BUILD)/diag-memory-semantics
	mkdir -p $(BUILD)/diag-memory-semantics
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-memory-semantics -simdir $(BUILD)/diag-memory-semantics -info-dir $(BUILD)/diag-memory-semantics \
		-g mkTbMainboardMemorySemantics bluespec/TbMainboardMemorySemantics.bsv 2>&1 | tee $(BUILD)/diag-memory-semantics/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-memory-semantics/compile.log; then \
		echo 'FAIL memory-semantics diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-memory-semantics -simdir $(BUILD)/diag-memory-semantics \
		-e mkTbMainboardMemorySemantics -o $(BUILD)/diag-memory-semantics/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 60s $(BUILD)/diag-memory-semantics/tb 2>&1 | tee $(BUILD)/diag-memory-semantics/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-memory-semantics/tb 2>&1 | tee $(BUILD)/diag-memory-semantics/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/diag-memory-semantics/run.log; then exit 1; fi
	@test "$$(grep -c '^MAINBOARDMEMTRACE|mask=' $(BUILD)/diag-memory-semantics/run.log)" -eq 10
	@for mask in 0001 0010 0100 1000 0011 1100 0101 1010 0000 1111; do \
		grep -q "^MAINBOARDMEMTRACE|mask=$$mask|.*|status=ok$$" $(BUILD)/diag-memory-semantics/run.log || exit 1; \
	done
	@grep -Fq 'MAINBOARDMEMSHARED|cpu_to_plio=ok|plio_to_cpu=ok|plio_be=1111|status=ok' $(BUILD)/diag-memory-semantics/run.log
	@grep -Fq 'PASS|memory-semantics|CPU partial stores, full reads, and CPU/PLIO shared memory semantics' $(BUILD)/diag-memory-semantics/run.log

test-byte-enable:
	rm -rf $(BUILD)/diag-byte-enable
	mkdir -p $(BUILD)/diag-byte-enable
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-byte-enable -simdir $(BUILD)/diag-byte-enable -info-dir $(BUILD)/diag-byte-enable \
		-g mkTbMainboardByteEnable bluespec/TbMainboardByteEnable.bsv 2>&1 | tee $(BUILD)/diag-byte-enable/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-byte-enable/compile.log; then \
		echo 'FAIL byte-enable diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-byte-enable -simdir $(BUILD)/diag-byte-enable \
		-e mkTbMainboardByteEnable -o $(BUILD)/diag-byte-enable/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-byte-enable/tb 2>&1 | tee $(BUILD)/diag-byte-enable/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-byte-enable/tb 2>&1 | tee $(BUILD)/diag-byte-enable/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/diag-byte-enable/run.log; then exit 1; fi
	@test "$$(grep -c '^MAINBOARDBETRACE|mask=' $(BUILD)/diag-byte-enable/run.log)" -eq 10
	@for mask in 0001 0010 0100 1000 0011 1100 0101 1010 0000 1111; do \
		grep -Fq "MAINBOARDBETRACE|mask=$$mask|status=ok" $(BUILD)/diag-byte-enable/run.log || exit 1; \
	done
	@grep -Fq 'PASS|byte-enable|CPU to Mainboard to MemoryController propagation and backpressure stability' $(BUILD)/diag-byte-enable/run.log

test-cpu-grant:
	rm -rf $(BUILD)/diag-cpu-grant
	mkdir -p $(BUILD)/diag-cpu-grant
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-grant -simdir $(BUILD)/diag-cpu-grant -info-dir $(BUILD)/diag-cpu-grant \
		-g mkTbMainboardCpuGrant bluespec/TbMainboardDiagnostics.bsv 2>&1 | tee $(BUILD)/diag-cpu-grant/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-cpu-grant/compile.log; then \
		echo 'FAIL CPU grant diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-grant -simdir $(BUILD)/diag-cpu-grant \
		-e mkTbMainboardCpuGrant -o $(BUILD)/diag-cpu-grant/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-cpu-grant/tb 2>&1 | tee $(BUILD)/diag-cpu-grant/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-cpu-grant/tb 2>&1 | tee $(BUILD)/diag-cpu-grant/run.log; \
	fi

test-cpu-write:
	rm -rf $(BUILD)/diag-cpu-write
	mkdir -p $(BUILD)/diag-cpu-write
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-write -simdir $(BUILD)/diag-cpu-write -info-dir $(BUILD)/diag-cpu-write \
		-g mkTbMainboardCpuWrite bluespec/TbMainboardDiagnostics.bsv 2>&1 | tee $(BUILD)/diag-cpu-write/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-cpu-write/compile.log; then \
		echo 'FAIL CPU write diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-write -simdir $(BUILD)/diag-cpu-write \
		-e mkTbMainboardCpuWrite -o $(BUILD)/diag-cpu-write/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-cpu-write/tb 2>&1 | tee $(BUILD)/diag-cpu-write/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-cpu-write/tb 2>&1 | tee $(BUILD)/diag-cpu-write/run.log; \
	fi

test-cpu-read:
	rm -rf $(BUILD)/diag-cpu-read
	mkdir -p $(BUILD)/diag-cpu-read
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-read -simdir $(BUILD)/diag-cpu-read -info-dir $(BUILD)/diag-cpu-read \
		-g mkTbMainboardCpuRead bluespec/TbMainboardDiagnostics.bsv 2>&1 | tee $(BUILD)/diag-cpu-read/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-cpu-read/compile.log; then \
		echo 'FAIL CPU read diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-cpu-read -simdir $(BUILD)/diag-cpu-read \
		-e mkTbMainboardCpuRead -o $(BUILD)/diag-cpu-read/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-cpu-read/tb 2>&1 | tee $(BUILD)/diag-cpu-read/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-cpu-read/tb 2>&1 | tee $(BUILD)/diag-cpu-read/run.log; \
	fi

test-reset-recovery:
	rm -rf $(BUILD)/diag-reset-recovery
	mkdir -p $(BUILD)/diag-reset-recovery
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-reset-recovery -simdir $(BUILD)/diag-reset-recovery -info-dir $(BUILD)/diag-reset-recovery \
		-g mkTbMainboardResetRecovery bluespec/TbMainboardDiagnostics.bsv 2>&1 | tee $(BUILD)/diag-reset-recovery/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-reset-recovery/compile.log; then \
		echo 'FAIL reset/recovery diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-reset-recovery -simdir $(BUILD)/diag-reset-recovery \
		-e mkTbMainboardResetRecovery -o $(BUILD)/diag-reset-recovery/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-reset-recovery/tb 2>&1 | tee $(BUILD)/diag-reset-recovery/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-reset-recovery/tb 2>&1 | tee $(BUILD)/diag-reset-recovery/run.log; \
	fi

test-plio-dma:
	rm -rf $(BUILD)/diag-plio-dma
	mkdir -p $(BUILD)/diag-plio-dma
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-plio-dma -simdir $(BUILD)/diag-plio-dma -info-dir $(BUILD)/diag-plio-dma \
		-g mkTbMainboardPlioDma bluespec/TbMainboardDiagnostics.bsv 2>&1 | tee $(BUILD)/diag-plio-dma/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-plio-dma/compile.log; then \
		echo 'FAIL PLIO DMA diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-plio-dma -simdir $(BUILD)/diag-plio-dma \
		-e mkTbMainboardPlioDma -o $(BUILD)/diag-plio-dma/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 30s $(BUILD)/diag-plio-dma/tb 2>&1 | tee $(BUILD)/diag-plio-dma/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-plio-dma/tb 2>&1 | tee $(BUILD)/diag-plio-dma/run.log; \
	fi

test-lifecycle-coverage:
	rm -rf $(BUILD)/diag-lifecycle-coverage
	mkdir -p $(BUILD)/diag-lifecycle-coverage
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-lifecycle-coverage -simdir $(BUILD)/diag-lifecycle-coverage -info-dir $(BUILD)/diag-lifecycle-coverage \
		-g mkTbMainboardLifecycleCoverage bluespec/TbMainboardLifecycleCoverage.bsv 2>&1 | tee $(BUILD)/diag-lifecycle-coverage/compile.log
	@if grep -q '(G0023)' $(BUILD)/diag-lifecycle-coverage/compile.log; then \
		echo 'FAIL lifecycle coverage contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/diag-lifecycle-coverage -simdir $(BUILD)/diag-lifecycle-coverage \
		-e mkTbMainboardLifecycleCoverage -o $(BUILD)/diag-lifecycle-coverage/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 45s $(BUILD)/diag-lifecycle-coverage/tb 2>&1 | tee $(BUILD)/diag-lifecycle-coverage/run.log; \
	else \
		set -o pipefail; $(BUILD)/diag-lifecycle-coverage/tb 2>&1 | tee $(BUILD)/diag-lifecycle-coverage/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/diag-lifecycle-coverage/run.log; then exit 1; fi
	@grep -Fq 'MAINBOARDLIFECYCLE|reset_outstanding=ok|stale_internal_state=ok' $(BUILD)/diag-lifecycle-coverage/run.log
	@grep -Fq 'MAINBOARDLIFECYCLE|fresh_recovery=ok' $(BUILD)/diag-lifecycle-coverage/run.log
	@grep -Fq 'MAINBOARDLIFECYCLE|plio_memory_path=ok|plio_be=1111|status=ok' $(BUILD)/diag-lifecycle-coverage/run.log
	@grep -Fq 'PASS|lifecycle-coverage|reset stale-state isolation, fresh recovery, and PLIO full-word memory path' $(BUILD)/diag-lifecycle-coverage/run.log

test-core:
	rm -rf $(BUILD)/core
	mkdir -p $(BUILD)/core
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/core -simdir $(BUILD)/core -info-dir $(BUILD)/core \
		-g mkTbMainboardRegisteredBackend bluespec/TbMainboardRegisteredBackend.bsv 2>&1 | tee $(BUILD)/core/compile.log
	@if grep -q '(G0023)' $(BUILD)/core/compile.log; then \
		echo 'FAIL registered-backend test contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/core -simdir $(BUILD)/core \
		-e mkTbMainboardRegisteredBackend -o $(BUILD)/core/tb-mainboard-fpga
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 60s $(BUILD)/core/tb-mainboard-fpga 2>&1 | tee $(BUILD)/core/run.log; \
	else \
		set -o pipefail; $(BUILD)/core/tb-mainboard-fpga 2>&1 | tee $(BUILD)/core/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/core/run.log; then \
		echo 'FAIL registered-backend integration emitted a failure marker'; exit 1; \
	fi
	@grep -q '^PASS|registered-backend|mainboard queued cycle matches fake backend handshake' $(BUILD)/core/run.log

test-qdx-b:
	rm -rf $(BUILD)/qdxb
	mkdir -p $(BUILD)/qdxb
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(QDXB_SEARCH)' \
		-bdir $(BUILD)/qdxb -simdir $(BUILD)/qdxb -info-dir $(BUILD)/qdxb \
		-g mkTbMainboardQDXBIntegration bluespec/TbMainboardQDXBIntegration.bsv 2>&1 | tee $(BUILD)/qdxb/compile.log
	@if grep -q '(G0023)' $(BUILD)/qdxb/compile.log; then \
		echo 'FAIL mainboard QDX-B test contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(QDXB_SEARCH)' \
		-bdir $(BUILD)/qdxb -simdir $(BUILD)/qdxb \
		-e mkTbMainboardQDXBIntegration -o $(BUILD)/qdxb/tb-mainboard-qdxb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 120s $(BUILD)/qdxb/tb-mainboard-qdxb 2>&1 | tee $(BUILD)/qdxb/run.log; \
	else \
		set -o pipefail; $(BUILD)/qdxb/tb-mainboard-qdxb 2>&1 | tee $(BUILD)/qdxb/run.log; \
	fi

test-lighting-plio0:
	rm -rf $(BUILD)/lighting-plio0
	mkdir -p $(BUILD)/lighting-plio0
	set -o pipefail; $(BSC) +RTS -K8M -RTS -u -sim -p '$(QDXB_SEARCH)' \
		-bdir $(BUILD)/lighting-plio0 -simdir $(BUILD)/lighting-plio0 -info-dir $(BUILD)/lighting-plio0 \
		-g mkTbMainboardLightingPlio0 bluespec/TbMainboardLightingPlio0.bsv 2>&1 | tee $(BUILD)/lighting-plio0/compile.log
	@if grep -q '(G0023)' $(BUILD)/lighting-plio0/compile.log; then \
		echo 'FAIL Lighting PLIO0 diagnostic contains a BSC always-false rule'; exit 1; \
	fi
	$(BSC) +RTS -K8M -RTS -sim -p '$(QDXB_SEARCH)' \
		-bdir $(BUILD)/lighting-plio0 -simdir $(BUILD)/lighting-plio0 \
		-e mkTbMainboardLightingPlio0 -o $(BUILD)/lighting-plio0/tb
	@if command -v timeout >/dev/null 2>&1; then \
		set -o pipefail; timeout 120s $(BUILD)/lighting-plio0/tb 2>&1 | tee $(BUILD)/lighting-plio0/run.log; \
	else \
		set -o pipefail; $(BUILD)/lighting-plio0/tb 2>&1 | tee $(BUILD)/lighting-plio0/run.log; \
	fi
	@if grep -q '^FAIL|' $(BUILD)/lighting-plio0/run.log; then exit 1; fi
	@grep -Fq 'MAINBOARDPLIO0TRACE|cpu_mmio=ok|iochannel=0|slot=0|worker=00001000|cap=00324501' $(BUILD)/lighting-plio0/run.log
	@grep -Fq 'PASS|lighting-plio0|CPU MMIO reaches physical QDX-B through Mainboard PLIO host' $(BUILD)/lighting-plio0/run.log

verilog-sanity:
	rm -rf $(BUILD)/rtl
	mkdir -p $(BUILD)/rtl/obj $(BUILD)/rtl/verilog
	$(BSC) +RTS -K8M -RTS -u -verilog -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/rtl/obj -vdir $(BUILD)/rtl/verilog -info-dir $(BUILD)/rtl/obj \
		-g mkMainboardFPGA bluespec/MainboardFPGA.bsv
	@test -f $(BUILD)/rtl/verilog/mkMainboardFPGA.v
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		generated_files="$$(find $(BUILD)/rtl/verilog -maxdepth 1 -name '*.v' -print | tr '\n' ' ')"; \
		$(YOSYS) -q -p "read_verilog $$generated_files; hierarchy -top mkMainboardFPGA; proc; opt; check"; \
	fi
	@echo 'PASS mainboard FPGA generated-Verilog/synthesis sanity'

clean:
	rm -rf $(BUILD)
