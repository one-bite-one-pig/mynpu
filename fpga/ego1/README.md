# EGo1 FPGA smoke test

This shell targets the XC7A35T EGo1 board. The board clock is 100 MHz on P17;
the reset and LED pins are from the EGo1 V2.2 manual. Check the board revision
and reset polarity before programming. The shell sets `LANES=1`, preloads the
8KB CPU image, and uses synchronous inferred BRAM for both CPU and NPU SRAM.
The NPU is the `LANES=1` single-port schedule, matching the storage timing
used by the FPGA integration smoke test.

Create a Vivado project with part `xc7a35tcsg324-1`, add the repository RTL
listed in `sim/soc.f`, add this top and `ego1.xdc`, and add
`generated/8k/cpu.hex` as a synthesis/simulation source. Set the top to
`ego1_soc_top`, run synthesis, implementation, and bitstream generation.

The first expected behavior is LED0 toggling. LED1 is the NPU interrupt and
LED2 is the CPU debug-halted status. The board's USB configuration JTAG does
not automatically drive `tck_i/tms_i/td_i/td_o`; use an external GPIO probe or
add a Xilinx BSCAN-to-DMI bridge if CPU Debug Module testing is required.
