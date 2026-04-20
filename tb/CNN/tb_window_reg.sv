`timescale 1ns / 1ps

module tb_window_reg;

  localparam DATA_WIDTH = 8;
  localparam CH = 4;
  localparam LINE_WIDTH = 256;
  localparam PIXEL_BITS = DATA_WIDTH * CH;
  localparam WINDOW_BITS = PIXEL_BITS * 9;

  logic clk;
  logic reset;
  logic col_valid;
  logic [PIXEL_BITS-1:0] row0_col;
  logic [PIXEL_BITS-1:0] row1_col;
  logic [PIXEL_BITS-1:0] row2_col;
  logic [$clog2(LINE_WIDTH)-1:0] col;

  logic [WINDOW_BITS-1:0] window_data;
  logic window_valid;

  window_reg #(
      .DATA_WIDTH(DATA_WIDTH),
      .CH(CH),
      .LINE_WIDTH(LINE_WIDTH)
  ) dut (
      .clk(clk),
      .reset(reset),
      .col_valid(col_valid),
      .row0_col(row0_col),
      .row1_col(row1_col),
      .row2_col(row2_col),
      .col(col),
      .window_data(window_data),
      .window_valid(window_valid)
  );

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // 특정 Row, Col에 대한 픽셀 생성 함수
  function [PIXEL_BITS-1:0] gen_pixel(input int r, input int c, input bit single_ch_mode);
    logic [7:0] ch0, ch1, ch2, ch3;
    if (r < 0) return 32'b0;  // 유효하지 않은 이전 행은 0 반환

    if (single_ch_mode) begin
      ch0 = c[7:0];
      ch1 = 8'h00;
      ch2 = 8'h00;
      ch3 = 8'h00;
    end else begin
      ch0 = c[7:0];
      ch1 = r[7:0];
      ch2 = 8'hAA;
      ch3 = 8'hBB;
    end
    return {ch3, ch2, ch1, ch0};
  endfunction

  // 시나리오 실행 Task
  task run_scenario(input string scenario_name, input bit single_ch_mode);
    $display("=== START SCENARIO: %s ===", scenario_name);

    for (int r = 0; r < 6; r++) begin
      for (int c = 0; c < LINE_WIDTH; c++) begin
        @(posedge clk);

        // line_buffer의 조건을 모방 (row가 1 이상일 때부터 col_valid 발생)
        col_valid <= (r >= 1) ? 1'b1 : 1'b0;

        row0_col <= gen_pixel(r - 2, c, single_ch_mode);
        row1_col <= gen_pixel(r - 1, c, single_ch_mode);
        row2_col <= gen_pixel(r, c, single_ch_mode);
        col <= c;
      end
      @(posedge clk);
      col_valid <= 0;
      #50;  // HBlank 시간 모방
    end
    $display("=== END SCENARIO: %s ===\n", scenario_name);
  endtask

  initial begin
    // 초기화
    reset = 1;
    col_valid = 0;
    row0_col = 0;
    row1_col = 0;
    row2_col = 0;
    col = 0;
    #20;
    reset = 0;
    #10;

    // 시나리오 1: 단일 채널 모드
    run_scenario("SINGLE_CHANNEL_MODE", 1);

    #100;

    // 시나리오 2: 전체 채널 모드
    run_scenario("ALL_CHANNELS_MODE", 0);

    #50;
    $finish;
  end

endmodule
