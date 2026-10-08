`timescale 1ns/1ps

// Lab 3：simple_npu 的 MMIO 壳（Task 2）
//   端口签名不要改：被 soc/rtl/my_npu_subsystem.sv 按名字例化。
//   这一层只负责"和总线打交道"：地址译码、ACT/WGT 寄存器组、CONTROL/STATUS、
//   OUT 读出；计算交给你在 Task 1 写好的 simple_npu_core（脉动阵列）。
//   计算：C = A · B，A/B/C 均为 4×4，元素 unsigned 4-bit。
//   MMIO 列优先：ACT[j*4+i] = A[i][j]，WGT[j*4+i] = B[i][j]，OUT[j*4+i] = C[i][j]。
//   读时序：douta 在请求后下一拍有效（与 axi2mem 1 拍 memory latency 匹配）。

module simple_npu_top (
    input  logic        clka,
    input  logic        rst_ni,
    input  logic        ena,
    input  logic        wea,
    input  logic [11:0] addra,
    input  logic [31:0] dina,
    output logic [31:0] douta
);

  //==============================================================
  // MMIO 地址常量，给你看的，不一定需要保留（但地址值本身不能变）。
  //==============================================================
  localparam logic [11:0] ADDR_CONTROL = 12'd0;
  localparam logic [11:0] ADDR_STATUS  = 12'd1;
  localparam logic [11:0] ACT_BASE     = 12'd16;     // word 16..31
  localparam logic [11:0] ACT_END      = 12'd31;
  localparam logic [11:0] WGT_BASE     = 12'd1024;   // word 1024..1039
  localparam logic [11:0] WGT_END      = 12'd1039;
  localparam logic [11:0] OUT_BASE     = 12'd2048;   // word 2048..2063
  localparam logic [11:0] OUT_END      = 12'd2063;

  logic [15:0][3:0]  act_reg;
  logic [15:0][3:0]  wgt_reg;
  logic [15:0][9:0]  out_reg;
  logic              npu_start;
  logic              npu_done;

  // A CONTROL write with bit 0 set is the one-cycle start pulse.  The
  // software writes all ACT/WGT words before this write, so the core samples
  // a complete, stable matrix on the same clock edge.
  assign npu_start = ena && wea && (addra == ADDR_CONTROL) && dina[0];

  simple_npu_core i_npu_core (
      .clk  (clka),
      .rst_ni(rst_ni),
      .start(npu_start),
      .done (npu_done),
      .act  (act_reg),
      .wgt  (wgt_reg),
      .out  (out_reg)
  );

  // MMIO writes update the two input register files.  MMIO reads are
  // synchronous: douta is updated one clock after ena is asserted, matching
  // the one-cycle SRAM latency used by the AXI-to-memory adapter.
  always_ff @(posedge clka or negedge rst_ni) begin
    if (!rst_ni) begin
      act_reg <= '0;
      wgt_reg <= '0;
      douta   <= 32'd0;
    end else begin
      if (ena && wea) begin
        if ((addra >= ACT_BASE) && (addra <= ACT_END))
          act_reg[addra - ACT_BASE] <= dina[3:0];
        else if ((addra >= WGT_BASE) && (addra <= WGT_END))
          wgt_reg[addra - WGT_BASE] <= dina[3:0];
      end

      if (ena && !wea) begin
        douta <= 32'd0;
        if (addra == ADDR_STATUS)
          douta <= {31'd0, npu_done};
        else if ((addra >= ACT_BASE) && (addra <= ACT_END))
          douta <= {28'd0, act_reg[addra - ACT_BASE]};
        else if ((addra >= WGT_BASE) && (addra <= WGT_END))
          douta <= {28'd0, wgt_reg[addra - WGT_BASE]};
        else if ((addra >= OUT_BASE) && (addra <= OUT_END))
          douta <= {22'd0, out_reg[addra - OUT_BASE]};
      end
    end
  end

endmodule
