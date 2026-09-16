SHELL := /bin/bash
BSC ?= bsc
YOSYS ?= yosys
ROOT := $(abspath ..)
BUILD := $(abspath build)
BASE_SEARCH := +:$(ROOT)/qli/bluespec:$(ROOT)/qic/bluespec:$(ROOT)/pti/bluespec:$(ROOT)/plio-tx/bluespec:$(ROOT)/plio-rax-host/bluespec:$(ROOT)/memory-controller/bluespec:$(abspath bluespec)
QDXB_SEARCH := $(BASE_SEARCH):$(ROOT)/qli16/bluespec:$(ROOT)/testbench/bluespec:$(ROOT)/qdx-a/bluespec:$(ROOT)/qdx-b/bluespec:$(ROOT)/qdx-b-card/bluespec

.PHONY: test test-isolated test-cpu-grant test-cpu-write test-cpu-read test-reset-recovery test-plio-dma test-core test-qdx-b verilog-sanity clean

test: test-isolated test-core test-qdx-b verilog-sanity

test-isolated: test-cpu-grant test-cpu-write test-cpu-read test-reset-recovery test-plio-dma

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

verilog-sanity:
	rm -rf $(BUILD)/rtl
	mkdir -p $(BUILD)/rtl/obj $(BUILD)/rtl/verilog
	$(BSC) +RTS -K8M -RTS -u -verilog -p '$(BASE_SEARCH)' \
		-bdir $(BUILD)/rtl/obj -vdir $(BUILD)/rtl/verilog -info-dir $(BUILD)/rtl/obj \
		-g mkMainboardFPGA bluespec/MainboardFPGA.bsv
	@test -f $(BUILD)/rtl/verilog/mkMainboardFPGA.v
	@if command -v $(YOSYS) >/dev/null 2>&1; then \
		BSC_PREFIX="$$(cd "$$(dirname "$$(command -v $(BSC))")/.." && pwd)"; \
		std_files="$$(find "$$BSC_PREFIX/lib/Verilog" -maxdepth 1 -name '*.v' ! -name '*Load.v' ! -name 'main.v' -print | tr '\n' ' ')"; \
		generated_files="$$(find $(BUILD)/rtl/verilog -maxdepth 1 -name '*.v' -print | tr '\n' ' ')"; \
		$(YOSYS) -q -p "read_verilog -lib $$std_files; read_verilog $$generated_files; hierarchy -check -top mkMainboardFPGA; proc; check"; \
	fi
	@echo 'PASS mainboard FPGA generated-Verilog/synthesis sanity'

clean:
	rm -rf $(BUILD)
