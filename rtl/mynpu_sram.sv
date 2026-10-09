// Synchronous CPU SRAM functional backend. Replace with the foundry macro
// through this interface; reset does not erase loaded program contents.
module mynpu_sram #(
  parameter integer SRAM_BYTES = 8192,
  parameter INIT_FILE = "",
  parameter bit FPGA_BRAM = 1'b0,
  parameter bit ASIC_MACRO = 1'b0
) (
  input logic clk_i, rst_ni, req_i, we_i,
  input logic [3:0] be_i,
  input logic [31:0] addr_i, wdata_i,
  output logic [31:0] rdata_o
);
  localparam integer WORDS = SRAM_BYTES / 4;
  // Kept at module scope for the existing simulation mailbox checker.  The
  // FPGA backend below does not use this array; it is the stable functional
  // backend/debug visibility used by the VCS testbench.
  logic [31:0] mem [0:WORDS-1];

  generate
    if (ASIC_MACRO) begin : g_asic_macro
      initial if (SRAM_BYTES != 8192) $fatal(1, "ASIC macro backend supports exactly 8KB");
      mynpu_sram_2048x32_asic i_macro (
          .clk_i(clk_i), .req_i(req_i), .we_i(we_i), .be_i(be_i),
          .addr_i(addr_i[12:2]), .wdata_i(wdata_i), .rdata_o(rdata_o)
      );
    end else if (FPGA_BRAM) begin : g_fpga_bram
      initial if (SRAM_BYTES != 8192) $fatal(1, "FPGA BRAM backend currently supports exactly 8KB");
      mynpu_sram_2048x32_fpga #(.INIT_FILE(INIT_FILE)) i_bram (
          .clk_i(clk_i), .req_i(req_i), .we_i(we_i), .be_i(be_i),
          .addr_i(addr_i[12:2]), .wdata_i(wdata_i), .rdata_o(rdata_o)
      );
    end else begin : g_functional
  integer index;
  initial begin
    if (SRAM_BYTES < 4096 || SRAM_BYTES % 4 != 0) $fatal(1, "Invalid CPU SRAM size");
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end
  // Plain always permits the supported FPGA/simulation RAM initial contents.
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rdata_o <= 0;
    else if (req_i) begin
      index = (addr_i - 32'h8000_0000) >> 2;
      rdata_o <= 0;
      if (index >= 0 && index < WORDS) begin
        rdata_o <= mem[index];
        if (we_i) begin
          if (be_i[0]) mem[index][7:0] <= wdata_i[7:0];
          if (be_i[1]) mem[index][15:8] <= wdata_i[15:8];
          if (be_i[2]) mem[index][23:16] <= wdata_i[23:16];
          if (be_i[3]) mem[index][31:24] <= wdata_i[31:24];
        end
      end
    end
  end
    end
  endgenerate
endmodule
