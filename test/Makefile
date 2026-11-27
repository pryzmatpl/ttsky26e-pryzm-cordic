# cocotb / Icarus test defaults for tt_um_pryzm_cordic.
# Pinned to the shuttle template's variables so tt-gds-action/gl_test can
# reuse this Makefile unchanged for the gate-level run.

SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v

ifneq ($(GATES),yes)

# RTL simulation
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate-level simulation: the netlist the GDS action copies in, plus the PDK
# primitives and the standard cells.
SIM_BUILD = sim_build/gl
COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

COMPILE_ARGS += -I$(SRC_DIR)

VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
MODULE = test

COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
