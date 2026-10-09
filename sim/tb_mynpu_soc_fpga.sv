`timescale 1ns/1ps

// FPGA-memory integration smoke test.  It intentionally omits DMI stimulus:
// the EGo1 shell boots the preloaded CPU image, while the separate Lab 6
// OpenOCD test exercises the exposed tck/tms/tdi/tdo pins.
module tb_mynpu_soc_fpga;
  logic clk=0, rst_ni=0;
  logic irq, halted;
  always #5 clk=~clk;
  mynpu_soc_top #(
    .CPU_SRAM_BYTES(8192), .NPU_SRAM_BYTES(8192), .NPU_LANES(1),
    .USE_FPGA_BRAM(1'b1), .CPU_INIT_FILE("generated/8k/cpu.hex")
  ) dut (
    .clk_i(clk), .rst_ni(rst_ni), .boot_ready_i(1'b1),
    .npu_irq_o(irq), .cpu_debug_halted_o(halted),
    .tck_i(1'b0), .tms_i(1'b1), .td_i(1'b0), .td_o()
  );
  initial begin
    repeat(10) @(posedge clk); rst_ni=1;
    wait(dut.i_mainmem.g_fpga_bram.i_bram.mem['h1fc0/4] === 32'hc0dec0de ||
         dut.i_mainmem.g_fpga_bram.i_bram.mem['h1fc0/4] === 32'hdeadbeef);
    if (dut.i_mainmem.g_fpga_bram.i_bram.mem['h1fc0/4] === 32'hdeadbeef)
      $fatal(1,"FPGA-BRAM CPU firmware failed code=%h",dut.i_mainmem.g_fpga_bram.i_bram.mem['h1fc4/4]);
    $display("[SOC-FPGA] PASS CPU BRAM + NPU single-port BRAM backend, cycles=%0d",
             dut.i_npu_subsystem.g_single_port.i_core.cycle_q);
    $finish;
  end
  initial begin #100000000; $fatal(1,"FPGA backend timeout"); end
endmodule
