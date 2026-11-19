TOP   := fpu
RTL   := $(wildcard rtl/*.sv)
TB    := tb/tb_fpu.sv
BUILD := build
N     ?= 40000

.PHONY: test lint synth clean

test: $(BUILD)/vectors.txt
	iverilog -g2012 -o $(BUILD)/tb.vvp $(RTL) $(TB)
	vvp -n $(BUILD)/tb.vvp +vectors=$(BUILD)/vectors.txt

$(BUILD)/vectors.txt: scripts/gen_vectors.py scripts/fp_ref.py
	@mkdir -p $(BUILD)
	python3 scripts/gen_vectors.py $@ $(N)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module $(TOP) $(RTL)

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog -sv $(RTL); synth -top $(TOP); tee -o $(BUILD)/synth_stat.txt stat"

clean:
	rm -rf $(BUILD)
