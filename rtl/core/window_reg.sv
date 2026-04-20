`timescale 1ns / 1ps

module window_reg #(
    parameter DATA_WIDTH = 8,
    parameter CH         = 4,
    parameter LINE_WIDTH = 256
) (
    input logic clk,
    input logic reset,

    input logic                     col_valid,
    input logic [DATA_WIDTH*CH-1:0] row0_col,
    input logic [DATA_WIDTH*CH-1:0] row1_col,
    input logic [DATA_WIDTH*CH-1:0] row2_col,

    input logic [$clog2(LINE_WIDTH)-1:0] col,  // CU에서 직접 사용

    output logic [DATA_WIDTH*CH*9-1:0] window_data,
    output logic                       window_valid
);
  localparam COL_WIDTH = DATA_WIDTH * CH * 3;

  // 2열만 레지스터에 버퍼링 (가장 오래된 열, 중간 열)
  logic [COL_WIDTH-1:0] col_regs[0:1];
  logic [COL_WIDTH-1:0] current_col;

  // 현재 스트리밍되어 들어오는 입력 열 (1클럭 지연 없이 즉시 사용)
  assign current_col = {row0_col, row1_col, row2_col};

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      col_regs[0] <= '0;
      col_regs[1] <= '0;
    end else if (col_valid) begin
      // Shift Register: current_col -> col_regs[0] -> col_regs[1]
      col_regs[1] <= col_regs[0];
      col_regs[0] <= current_col;
    end
  end

  // 최신 입력을 즉시 결합하여 1클럭 지연 제거
  // 배열 순서: {col-2 (오래된 열), col-1 (중간 열), col (현재 열)}
  assign window_data  = {col_regs[1], col_regs[0], current_col};

  // 3x3 윈도우는 열 인덱스가 2 (3번째 열)에 도달했을 때부터 유효함
  assign window_valid = col_valid & (col >= ($clog2(LINE_WIDTH))'(1));

endmodule
