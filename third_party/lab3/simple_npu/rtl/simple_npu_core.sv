`timescale 1ns/1ps

// 4x4 unsigned 4-bit matrix-multiply core.
// Inputs and outputs use the Lab 1/Lab 3 column-major convention:
//   act[j*4+i] = A[i][j], wgt[j*4+i] = B[i][j], out[j*4+i] = C[i][j].
module simple_npu_core (
    input  logic             clk,
    input  logic             rst_ni,
    input  logic             start,
    output logic             done,
    input  logic [15:0][3:0] act,
    input  logic [15:0][3:0] wgt,
    output logic [15:0][9:0] out
);

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
  state_t state_q, state_d;
  logic [1:0] k_q, k_d;
  logic       pe_clr, pe_en;
  logic [15:0][9:0] pe_acc;

  assign done   = (state_q == S_DONE);
  assign pe_en  = (state_q == S_RUN);
  // Clear on both IDLE->RUN and DONE->RUN, before the first MAC cycle.
  assign pe_clr = start && (state_q != S_RUN);

  always_comb begin
    state_d = state_q;
    k_d     = k_q;
    case (state_q)
      S_IDLE: begin
        if (start) begin
          state_d = S_RUN;
          k_d     = 2'd0;
        end
      end
      S_RUN: begin
        if (k_q == 2'd3) begin
          state_d = S_DONE;
          k_d     = 2'd0;
        end else begin
          k_d = k_q + 2'd1;
        end
      end
      S_DONE: begin
        if (start) begin
          state_d = S_RUN;
          k_d     = 2'd0;
        end
      end
      default: begin
        state_d = S_IDLE;
        k_d     = 2'd0;
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      k_q     <= 2'd0;
    end else begin
      state_q <= state_d;
      k_q     <= k_d;
    end
  end

  genvar i, j;
  generate
    for (i = 0; i < 4; i = i + 1) begin : gen_i
      for (j = 0; j < 4; j = j + 1) begin : gen_j
        simple_npu_pe u_pe (
            .clk   (clk),
            .rst_ni(rst_ni),
            .clr   (pe_clr),
            .en    (pe_en),
            .a     (act[k_q * 4 + i]),
            .b     (wgt[j * 4 + k_q]),
            .acc   (pe_acc[j * 4 + i])
        );
      end
    end
  endgenerate

  assign out = pe_acc;

endmodule
