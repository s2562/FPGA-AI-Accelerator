`timescale 1ns / 1ps

module line_buffer #(
    parameter LINE_WIDTH = 256,
    parameter DATA_WIDTH = 8,
    parameter CH         = 4
) (
    input logic clk,
    input logic reset,

    // FSM 공급 신호
    input logic                          pixel_valid,
    input logic [     DATA_WIDTH*CH-1:0] pixel_in,
    input logic [$clog2(LINE_WIDTH)-1:0] col,
    input logic [$clog2(LINE_WIDTH)-1:0] row,

    // 출력
    output logic [DATA_WIDTH*CH-1:0] row0_col,  // 2행 전
    output logic [DATA_WIDTH*CH-1:0] row1_col,  // 1행 전
    output logic [DATA_WIDTH*CH-1:0] row2_col,  // 현재 행
    output logic                     col_valid
);

  // BRAM 추론용 unpacked array
  logic [DATA_WIDTH*CH-1:0] line_mem0[0:LINE_WIDTH-1];  // 2행 전
  logic [DATA_WIDTH*CH-1:0] line_mem1[0:LINE_WIDTH-1];  // 1행 전

  always_ff @(posedge clk) begin
    if (pixel_valid) begin
      line_mem0[col] <= line_mem1[col];
      line_mem1[col] <= pixel_in;
    end
  end

  assign row0_col  = line_mem0[col];
  assign row1_col  = line_mem1[col];
  assign row2_col  = pixel_in;

  // [수정] 방식 A: line_buffer는 row >= 1이면 즉시 valid
  // col 조건은 window_reg가 담당
  assign col_valid = pixel_valid & (row >= ($clog2(LINE_WIDTH))'(1));

endmodule
