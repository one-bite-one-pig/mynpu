// Minimal EGo1 smoke-test shell.  It boots the preloaded CPU image and uses
// LEDs for heartbeat/IRQ/debug visibility.  It intentionally leaves the
// RISC-V DMI pins inactive; the board's configuration JTAG is not the CPU's
// JTAG TAP.  Add a BSCAN bridge or external GPIO probe for DMI testing.
module ego1_soc_top #(
  parameter bit RESET_ACTIVE_LOW = 1'b1
) (
  input  logic       sys_clk_i,
  input  logic       reset_i,
  output logic [7:0] led_o
);
  logic rst_ni;
  logic npu_irq;
  logic cpu_debug_halted;
  logic [25:0] heartbeat_q;

  assign rst_ni = RESET_ACTIVE_LOW ? reset_i : ~reset_i;

  always @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) heartbeat_q <= '0;
    else heartbeat_q <= heartbeat_q + 1'b1;
  end

  mynpu_soc_top #(
      .CPU_SRAM_BYTES(8192),
      .NPU_SRAM_BYTES(8192),
      .NPU_LANES(1),
      .USE_FPGA_BRAM(1'b1),
      .CPU_INIT_FILE("generated/8k/cpu.hex"),
      .NPU_INIT_FILE("")
  ) i_soc (
      .clk_i(sys_clk_i), .rst_ni(rst_ni), .boot_ready_i(1'b1),
      .npu_irq_o(npu_irq), .cpu_debug_halted_o(cpu_debug_halted),
      .tck_i(1'b0), .tms_i(1'b1), .td_i(1'b0), .td_o()
  );

  assign led_o[0] = heartbeat_q[25];
  assign led_o[1] = npu_irq;
  assign led_o[2] = cpu_debug_halted;
  assign led_o[7:3] = 5'b0;
endmodule
