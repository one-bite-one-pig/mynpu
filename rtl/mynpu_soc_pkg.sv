package mynpu_soc_pkg;
  localparam logic [31:0] DM_BASE = 32'h0000_0000;
  localparam logic [31:0] DM_LENGTH = 32'h0000_1000;
  localparam logic [31:0] BOOT_BASE = 32'h0001_0000;
  localparam logic [31:0] SRAM_BASE = 32'h8000_0000;
  localparam logic [31:0] NPU_BASE = 32'h7000_0000;
  localparam logic [31:0] NPU_LENGTH = 32'h0001_0000;
endpackage
