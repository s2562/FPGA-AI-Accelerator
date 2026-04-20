`timescale 1ns / 1ps

module tb_scaler;

  // ------------------------------------------------------------------------
  // Parameters
  // ------------------------------------------------------------------------
  localparam IN_WIDTH = 20;
  localparam SCALE_WIDTH = 8;
  localparam OUT_WIDTH = 8;
  localparam OUT_CH = 6;

  // ------------------------------------------------------------------------
  // Signals
  // ------------------------------------------------------------------------
  logic                               clk;
  logic                               reset;
  logic                               valid_in;
  logic signed [ IN_WIDTH*OUT_CH-1:0] data_in;
  logic signed [     SCALE_WIDTH-1:0] scale_factor;

  logic signed [OUT_WIDTH*OUT_CH-1:0] data_out;
  logic                               valid_out;

  // ------------------------------------------------------------------------
  // Clock Generation (100MHz)
  // ------------------------------------------------------------------------
  always #5 clk = ~clk;

  // ------------------------------------------------------------------------
  // DUT Instantiation
  // ------------------------------------------------------------------------
  scaler #(
      .IN_WIDTH(IN_WIDTH),
      .SCALE_WIDTH(SCALE_WIDTH),
      .OUT_WIDTH(OUT_WIDTH),
      .OUT_CH(OUT_CH)
  ) dut (
      .clk(clk),
      .reset(reset),
      .valid_in(valid_in),
      .data_in(data_in),
      .scale_factor(scale_factor),
      .data_out(data_out),
      .valid_out(valid_out)
  );

  // ------------------------------------------------------------------------
  // Task: CH[0] 1-Cycle 검증 (향후 Row/Col 반복문에 그대로 사용 가능)
  // ------------------------------------------------------------------------
  task test_ch0_scenario(
      input int tc_num, input string tc_name, input logic signed [SCALE_WIDTH-1:0] sf,
      input logic signed [IN_WIDTH-1:0] din0, input logic signed [OUT_WIDTH-1:0] expected_out);
    logic signed [OUT_WIDTH-1:0] actual_out;
    begin
      // 1. Data Drive (Negative edge에서 안전하게 데이터 인가)
      @(negedge clk);
      valid_in              = 1'b1;
      scale_factor          = sf;
      data_in               = '0;  // CH[1]~CH[5]는 모두 0으로 초기화
      data_in[IN_WIDTH-1:0] = din0;  // CH[0]에만 데이터 인가

      // 2. 파이프라인 지연 대기 & valid_in 끄기
      @(negedge clk);
      valid_in = 1'b0;

      // 3. 결과 검증 (valid_out이 1일 때)
      if (valid_out) begin
        actual_out = data_out[OUT_WIDTH-1:0];  // CH[0] 데이터 추출

        if (actual_out === expected_out) begin
          $display("[PASS] TC%0d: %-25s | SF:%4d, In:%6d -> Out:%4d", tc_num, tc_name, sf, din0,
                   actual_out);
        end else begin
          $display("[FAIL] TC%0d: %-25s | SF:%4d, In:%6d -> Expected:%4d, Got:%4d", tc_num,
                   tc_name, sf, din0, expected_out, actual_out);
        end
      end else begin
        $display("[ERROR] TC%0d: valid_out signal missed!", tc_num);
      end
    end
  endtask

  // ------------------------------------------------------------------------
  // Test Sequence
  // ------------------------------------------------------------------------
  initial begin
    clk = 0;
    reset = 1;
    valid_in = 0;
    data_in = '0;
    scale_factor = '0;

    #25;
    reset = 0;
    #10;

    $display("==================================================================");
    $display("   Scaler CH[0] Intensive Test Started (Q0.8 Scale Factor)        ");
    $display("==================================================================");

    // Task 인자: (TC번호, 시나리오명, Scale_Factor, CH0입력, 예상출력)
    // 참고: Scale Factor가 32 이면, 32/256 = 0.125 (1/8배)를 의미합니다.

    // [TC 1~2] 정상적인 스케일링 범위 (오버플로우 없음)
    test_ch0_scenario(1, "Normal Positive", 8'sd32, 20'sd500, 8'sd62);  // 500 * 0.125 = 62.5 -> 62
    test_ch0_scenario(2, "Normal Negative", 8'sd32, -20'sd500,
                      -8'sd62);  // -500 * 0.125 = -62.5 -> -62

    // [TC 3~4] 정확히 INT8 최댓값/최솟값에 걸치는 경우 (경계값 테스트)
    test_ch0_scenario(3, "Exact Max (+127)", 8'sd32, 20'sd1016, 8'sd127);  // 1016 * 0.125 = 127
    test_ch0_scenario(4, "Exact Min (-128)", 8'sd32, -20'sd1024, -8'sd128);  // -1024 * 0.125 = -128

    // [TC 5~6] 범위 초과로 인한 Clamping (오버플로우/언더플로우 제한)
    test_ch0_scenario(5, "Positive Clamping", 8'sd32, 20'sd2000,
                      8'sd127);  // 2000 * 0.125 = 250 -> 127로 클램핑
    test_ch0_scenario(6, "Negative Clamping", 8'sd32, -20'sd2000,
                      -8'sd128);  // -2000 * 0.125 = -250 -> -128로 클램핑

    // [TC 7] Scale Factor가 0인 경우 (가중치가 완전히 0이 된 필터)
    test_ch0_scenario(7, "Scale Factor Zero", 8'sd0, 20'sd9999, 8'sd0);  // 9999 * 0 = 0

    // [TC 8] 음수 Scale Factor 인가 (수학적으로 부호가 뒤집히는지 확인)
    test_ch0_scenario(8, "Negative Scale", -8'sd32, 20'sd500, -8'sd62);  // 500 * (-0.125) = -62

    // [TC 9] 값이 너무 작아서 0으로 소멸(Truncation)되는 경우
    test_ch0_scenario(9, "Truncate to Zero", 8'sd32, 20'sd5,
                      8'sd0);  // 5 * 0.125 = 0.625 -> (shift 연산 시 0)

    // [TC 10] 최댓값 스케일 팩터 (127/256 ≒ 0.496)
    test_ch0_scenario(10, "Max Scale Factor", 8'sd127, 20'sd100,
                      8'sd49);  // 100 * 127 = 12700, 12700 >>> 8 = 49

    $display("==================================================================");
    $display("   Phase 1: 10 Basic Scenarios Completed                          ");
    $display("==================================================================");

    /* 
        // ====================================================================
        // [향후 확장] 256 Col x 6 Row 반복 테스트 예시 (주석 해제 후 사용)
        // ====================================================================
        $display("Starting 256x6 Loop Test for Maxpool Integration...");
        for (int row = 0; row < 6; row++) begin
            for (int col = 0; col < 256; col++) begin
                // 임의의 동적 데이터 생성 (예: col 값을 데이터로 활용)
                logic signed [19:0] dyn_data = col * 10;
                // 매번 기대값을 직접 계산하기 어려우므로, 예상값 계산 함수를 따로 만들거나
                // valid_out만 체크하는 용도로 사용할 수 있습니다.
                // test_ch0_scenario(row*256 + col, "Loop Test", 8'sd32, dyn_data, (dyn_data*32) >>> 8);
            end
        end
        */

    #50;
    $finish;
  end

endmodule
