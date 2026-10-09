// FPGA prototype backend for the foundry RA1SHD_2048x32M8 interface.
//
// The foundry macro is a synchronous, single-port 2048x32 SRAM with four
// active-low byte write enables.  This implementation deliberately keeps the
// same one-request-per-cycle contract and uses a synchronous read so Vivado can
// infer block RAM.  It is not the foundry macro model and does not replace the
// ASIC wrapper used for synthesis.
module mynpu_sram_2048x32_fpga #(
  parameter INIT_FILE = ""
) (
  input  logic        clk_i,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [10:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o
);
  (* ram_style = "block" *) logic [31:0] mem [0:2047];

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // No reset is applied to the memory array, matching the foundry macro.
  // The CPU image is loaded through the initialization file for FPGA smoke
  // tests; an ASIC boot must load the SRAM through Debug/SBA or another ROM.
  always @(posedge clk_i) begin
    if (req_i) begin
      rdata_o <= mem[addr_i];
      if (we_i) begin
        if (be_i[0]) mem[addr_i][7:0]   <= wdata_i[7:0];
        if (be_i[1]) mem[addr_i][15:8]  <= wdata_i[15:8];
        if (be_i[2]) mem[addr_i][23:16] <= wdata_i[23:16];
        if (be_i[3]) mem[addr_i][31:24] <= wdata_i[31:24];
      end
    end
  end
endmodule
