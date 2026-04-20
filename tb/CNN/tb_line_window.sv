`timescale 1ns / 1ps

module tb_line_window;

  // 파라미터 설정
  localparam LINE_WIDTH = 256;
  localparam DATA_WIDTH = 8;
  localparam CH = 4;
  localparam PIXEL_BITS = DATA_WIDTH * CH;
  localparam WINDOW_BITS = PIXEL_BITS * 9;

  // TB 제어 신호
  logic clk;
  logic reset;

  // 입력 스트리밍 신호
  logic pixel_valid;
  logic [PIXEL_BITS-1:0] pixel_in;
  logic [$clog2(LINE_WIDTH)-1:0] col;
  logic [$clog2(LINE_WIDTH)-1:0] row;

  // 내부 연결 신호
  logic [PIXEL_BITS-1:0] row0_col;
  logic [PIXEL_BITS-1:0] row1_col;
  logic [PIXEL_BITS-1:0] row2_col;
  logic lb_col_valid;

  // 최종 출력 신호
  logic [WINDOW_BITS-1:0] window_data;
  logic window_valid;

  // 1. Line Buffer 인스턴스화
  line_buffer #(
      .LINE_WIDTH(LINE_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .CH(CH)
  ) dut_lb (
      .clk(clk),
      .reset(reset),
      .pixel_valid(pixel_valid),
      .pixel_in(pixel_in),
      .col(col),
      .row(row),
      .row0_col(row0_col),
      .row1_col(row1_col),
      .row2_col(row2_col),
      .col_valid(lb_col_valid)
  );

  // 2. Window Register 인스턴스화
  window_reg #(
      .DATA_WIDTH(DATA_WIDTH),
      .CH(CH),
      .LINE_WIDTH(LINE_WIDTH)
  ) dut_wr (
      .clk(clk),
      .reset(reset),
      .col_valid(lb_col_valid),
      .row0_col(row0_col),
      .row1_col(row1_col),
      .row2_col(row2_col),
      .col(col),
      .window_data(window_data),
      .window_valid(window_valid)
  );

  // 클럭 생성 (100MHz)
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // ==========================================================
  // 🔍 Verification Logger (Console Matrix Monitor)
  // ==========================================================
  // posedge 대신 negedge를 사용하여, 데이터와 col 값이 완전히
  // 안정화된 클럭의 정중앙에서 로그를 캡처하도록 변경합니다.
  always_ff @(negedge clk) begin
    if (window_valid && row == 2 && col >= 1 && col <= 4) begin
      $display("--------------------------------------------------");
      $display("[TIME: %0t] Valid Window Output at (Row: %0d, Col: %0d)", $time, row, col);

      $display("           [Left(c-2)]   [Mid(c-1)]    [Right(c)]");
      $display("[Top(r-2)]     %2h            %2h             %2h", window_data[256+:8],
               window_data[160+:8], window_data[64+:8]);
      $display("[Mid(r-1)]     %2h            %2h             %2h", window_data[224+:8],
               window_data[128+:8], window_data[32+:8]);
      $display("[Bot(r)]       %2h            %2h             %2h", window_data[192+:8],
               window_data[96+:8], window_data[0+:8]);
      $display("--------------------------------------------------\n");
    end
  end
  // 시나리오 실행 Task
  task run_scenario(input string scenario_name, input bit single_ch_mode);
    logic [7:0] ch0, ch1, ch2, ch3;
    $display("\n==================================================");
    $display("🚀 START SCENARIO: %s", scenario_name);
    $display("==================================================\n");

    for (int r = 0; r < 6; r++) begin
      for (int c = 0; c < LINE_WIDTH; c++) begin
        @(posedge clk);
        pixel_valid <= 1;
        col <= c;
        row <= r;

        // 단일 채널 모드: CH0에만 column 값을 넣어 데이터 이동(Shift) 추적
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
        pixel_in <= {ch3, ch2, ch1, ch0};
      end
      @(posedge clk);
      pixel_valid <= 0;
      #50;  // HBlank
    end
  endtask

  // 메인 테스트 시퀀스
  initial begin
    reset = 1;
    pixel_valid = 0;
    pixel_in = 0;
    col = 0;
    row = 0;
    #20;
    reset = 0;
    #10;

    // 시나리오 1: 단일 채널 모드 실행 (이때 매트릭스 로그가 출력됨)
    run_scenario("SINGLE_CHANNEL_MODE", 1);

    #50;
    $finish;
  end

endmodule
