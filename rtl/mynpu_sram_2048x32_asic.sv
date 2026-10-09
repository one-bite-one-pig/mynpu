// Wrapper for the foundry macro supplied outside this public repository.
// Compile this file together with RA1SHD_2048x32M8.v in the ASIC RTL/gate
// simulation or synthesis flow.  The macro package itself is proprietary and
// is intentionally not copied into GitHub.
module mynpu_sram_2048x32_asic (
  input  logic        clk_i,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [10:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o
);
  wire [3:0] wen_n = we_i ? ~be_i : 4'b1111;
  wire [31:0] q;

  RA1SHD_2048x32M8 i_macro (
      .Q(q), .CLK(clk_i), .CEN(~req_i), .WEN(wen_n), .A(addr_i),
      .D(wdata_i), .OEN(1'b0)
  );

  assign rdata_o = q;
endmodule
