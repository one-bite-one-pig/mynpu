`timescale 1ns/1ps

// One output-stationary processing element for the 4x4 GEMM.
module simple_npu_pe (
    input  logic       clk,
    input  logic       rst_ni,
    input  logic       clr,
    input  logic       en,
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic [9:0] acc
);

  // 4-bit x 4-bit is at most 225; four products fit in 10 bits (max 900).
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni)
      acc <= 10'd0;
    else if (clr)
      acc <= 10'd0;
    else if (en)
      acc <= acc + (a * b);
  end

endmodule
