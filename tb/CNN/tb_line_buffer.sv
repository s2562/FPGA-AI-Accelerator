`timescale 1ns / 1ps

module tb_line_buffer;

  localparam LINE_WIDTH = 256;
  localparam DATA_WIDTH = 8;
  localparam CH = 4;
  localparam PIXEL_BITS = DATA_WIDTH * CH;

  logic clk;
  logic reset;
  logic pixel_valid;
  logic [PIXEL_BITS-1:0] pixel_in;
  logic [$clog2(LINE_WIDTH)-1:0] col;
  logic [$clog2(LINE_WIDTH)-1:0] row;

  logic [PIXEL_BITS-1:0] row0_col;
  logic [PIXEL_BITS-1:0] row1_col;
  logic [PIXEL_BITS-1:0] row2_col;
  logic col_valid;

  line_buffer #(
      .LINE_WIDTH(LINE_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .CH(CH)
  ) dut (
      .clk(clk),
      .reset(reset),
      .pixel_valid(pixel_valid),
      .pixel_in(pixel_in),
      .col(col),
      .row(row),
      .row0_col(row0_col),
      .row1_col(row1_col),
      .row2_col(row2_col),
      .col_valid(col_valid)
  );

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // 시나리오 실행 Task
  task run_scenario(input string scenario_name, input bit single_ch_mode);
    logic [7:0] ch0, ch1, ch2, ch3;
    $display("=== START SCENARIO: %s ===", scenario_name);

    for (int r = 0; r < 6; r++) begin
      for (int c = 0; c < LINE_WIDTH; c++) begin
        @(posedge clk);
        pixel_valid <= 1;
        col <= c;
        row <= r;

        // 모드에 따른 데이터 생성
        if (single_ch_mode) begin
          ch0 = c[7:0];  // CH0만 값을 가짐
          ch1 = 8'h00;
          ch2 = 8'h00;
          ch3 = 8'h00;
        end else begin
          ch0 = c[7:0];  // CH0: Column index
          ch1 = r[7:0];  // CH1: Row index
          ch2 = 8'hAA;  // CH2: Fixed pattern AA
          ch3 = 8'hBB;  // CH3: Fixed pattern BB
        end

        pixel_in <= {ch3, ch2, ch1, ch0};
      end
      @(posedge clk);
      pixel_valid <= 0;
      #50;  // HBlank 시간 모방
    end
    $display("=== END SCENARIO: %s ===\n", scenario_name);
  endtask

  initial begin
    // 초기화
    reset = 1;
    pixel_valid = 0;
    pixel_in = 0;
    col = 0;
    row = 0;
    #20;
    reset = 0;
    #10;

    // 시나리오 1: 단일 채널 디버깅 (Spatial Movement 관찰용)
    run_scenario("SINGLE_CHANNEL_MODE", 1);

    #100;

    // 시나리오 2: 전체 채널 디버깅 (Channel Alignment 관찰용)
    run_scenario("ALL_CHANNELS_MODE", 0);

    #50;
    $finish;
  end

endmodule
