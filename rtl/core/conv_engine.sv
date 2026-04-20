`timescale 1ns / 1ps

module conv_engine #(
    parameter DATA_WIDTH  = 8,
    parameter IN_CH       = 4,
    parameter OUT_CH      = 6,
    parameter SCALE_WIDTH = 8,
    parameter MAC_WIDTH   = 20,
    parameter LINE_WIDTH  = 256
) (
    input logic clk,
    input logic reset,

    // ── control_unit 제어 ───────────────────────────
    input logic                          mac_en,
    input logic                          accum_clr,
    input logic                          pixel_valid,
    input logic [  DATA_WIDTH*IN_CH-1:0] pixel_in,
    input logic                          leaky_relu_en,
    input logic                          maxpool_en,
    input logic [                   1:0] kernel_mode,
    input logic [$clog2(LINE_WIDTH)-1:0] row,
    input logic [$clog2(LINE_WIDTH)-1:0] col,
    input logic [  $clog2(LINE_WIDTH):0] current_width,

    // ── weight/bias/scale 외부 공급 ─────────────────
    // mac_array가 OUT_CH*IN_CH*9개 weight를 한 번에 받는 구조
    input logic signed [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] kernel,
    input logic signed [              SCALE_WIDTH-1:0] scale_factor,
    input logic signed [        DATA_WIDTH*OUT_CH-1:0] bias,

    // ── 출력 ────────────────────────────────────────
    output logic signed [DATA_WIDTH*OUT_CH-1:0] pp_out,
    output logic                                pp_valid
);

    logic        [  DATA_WIDTH*IN_CH-1:0] row0_col;
    logic        [  DATA_WIDTH*IN_CH-1:0] row1_col;
    logic        [  DATA_WIDTH*IN_CH-1:0] row2_col;

    logic                                 col_valid;
    logic                                 window_valid;
    logic        [DATA_WIDTH*IN_CH*9-1:0] window_data;

    logic signed [  MAC_WIDTH*OUT_CH-1:0] mac_out;
    logic                                 mac_valid;

    // --------------------------------------------------
    // line_buffer
    // FSM의 row/col/current_width를 직접 사용
    // --------------------------------------------------
    line_buffer #(
        .LINE_WIDTH(LINE_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .CH        (IN_CH)
    ) u_line_buffer (
        .clk          (clk),
        .reset        (reset),
        .pixel_valid  (pixel_valid),
        .pixel_in     (pixel_in),
        .col          (col),
        .row          (row),
        .current_width(current_width),
        .row0_col     (row0_col),
        .row1_col     (row1_col),
        .row2_col     (row2_col),
        .col_valid    (col_valid)
    );

    // --------------------------------------------------
    // window_reg
    // 열 슬라이딩으로 3x3xCH 윈도우 생성
    // --------------------------------------------------
    window_reg #(
        .DATA_WIDTH(DATA_WIDTH),
        .CH        (IN_CH),
        .LINE_WIDTH(LINE_WIDTH)
    ) u_window_reg (
        .clk         (clk),
        .reset       (reset),
        .col_valid   (col_valid),
        .row0_col    (row0_col),
        .row1_col    (row1_col),
        .row2_col    (row2_col),
        .col         (col),
        .window_valid(window_valid),
        .window_data (window_data)
    );

    // --------------------------------------------------
    // mac_array
    // zero padding은 row/col/current_width 기반
    // --------------------------------------------------
    mac_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .IN_CH     (IN_CH),
        .OUT_CH    (OUT_CH)
    ) u_mac_array (
        .clk          (clk),
        .reset        (reset),
        .mac_en       (mac_en),
        .accum_clr    (accum_clr),
        .kernel_mode  (kernel_mode),
        .window_valid (window_valid),
        .window_data  (window_data),
        .kernel       (kernel),
        .row          (row),
        .col          (col),
        .current_width(current_width),
        .mac_out      (mac_out),
        .mac_valid    (mac_valid)
    );

    // --------------------------------------------------
    // post_process
    // scaler -> bias -> leaky_relu -> maxpool
    // --------------------------------------------------
    post_process #(
        .IN_WIDTH   (MAC_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .SCALE_WIDTH(SCALE_WIDTH),
        .OUT_CH     (OUT_CH)
    ) u_post_process (
        .clk          (clk),
        .reset        (reset),
        .mac_valid    (mac_valid),
        .mac_out      (mac_out),
        .leaky_relu_en(leaky_relu_en),
        .maxpool_en   (maxpool_en),
        .scale_factor (scale_factor),
        .bias         (bias),
        .row          (row),
        .col          (col),
        .pp_out       (pp_out),
        .pp_valid     (pp_valid)
    );

endmodule
