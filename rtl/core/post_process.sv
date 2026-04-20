// rtl/post_process.sv
// Post-Process 상위 모듈: Scaler → Bias → LeakyReLU → MaxPool

module post_process #(
    parameter IN_WIDTH    = 20,  // mac_out 비트폭
    parameter DATA_WIDTH  = 8,   // INT8
    parameter SCALE_WIDTH = 8,
    parameter OUT_CH      = 6
) (
    input  logic                                clk,
    input  logic                                reset,
    // ── MAC 결과 입력 ──
    input  logic                                mac_valid,
    input  logic signed [  IN_WIDTH*OUT_CH-1:0] mac_out,
    // ── FSM 제어 신호 ──
    input  logic                                leaky_relu_en,
    input  logic                                maxpool_en,
    // ── 파라미터 (외부 ROM에서 공급) ──
    input  logic signed [      SCALE_WIDTH-1:0] scale_factor,
    input  logic signed [DATA_WIDTH*OUT_CH-1:0] bias,
    // ── FSM 공간 카운터 (MaxPool용) ──
    input  logic        [                  7:0] row,
    input  logic        [                  7:0] col,
    // ── 최종 출력 ──
    output logic signed [DATA_WIDTH*OUT_CH-1:0] pp_out,
    output logic                                pp_valid
);

    // Stage 연결 신호
    logic signed [DATA_WIDTH*OUT_CH-1:0] scaled_out, bias_out, relu_out;
    logic scaler_valid, bias_valid, relu_valid;

    // [1] Scaler
    scaler #(
        .IN_WIDTH(IN_WIDTH),
        .SCALE_WIDTH(SCALE_WIDTH),
        .OUT_WIDTH(DATA_WIDTH),
        .OUT_CH(OUT_CH)
    ) u_scaler (
        .clk         (clk),
        .reset       (reset),
        .valid_in    (mac_valid),
        .data_in     (mac_out),
        .scale_factor(scale_factor),
        .data_out    (scaled_out),
        .valid_out   (scaler_valid)
    );

    // [2] Bias
    bias #(
        .DATA_WIDTH(DATA_WIDTH),
        .OUT_CH(OUT_CH)
    ) u_bias (
        .clk      (clk),
        .reset    (reset),
        .valid_in (scaler_valid),
        .data_in  (scaled_out),
        .bias     (bias),
        .data_out (bias_out),
        .valid_out(bias_valid)
    );

    // [3] LeakyReLU
    leaky_relu #(
        .DATA_WIDTH(DATA_WIDTH),
        .OUT_CH(OUT_CH)
    ) u_relu (
        .clk          (clk),
        .reset        (reset),
        .valid_in     (bias_valid),
        .leaky_relu_en(leaky_relu_en),
        .data_in      (bias_out),
        .data_out     (relu_out),
        .valid_out    (relu_valid)
    );

    // [4] MaxPool
    maxpool #(
        .DATA_WIDTH(DATA_WIDTH),
        .OUT_CH(OUT_CH)
    ) u_maxpool (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (relu_valid),
        .maxpool_en(maxpool_en),
        .row       (row),
        .col       (col),
        .data_in   (relu_out),
        .data_out  (pp_out),
        .valid_out (pp_valid)
    );

endmodule
