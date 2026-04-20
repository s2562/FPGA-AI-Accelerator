`timescale 1ns / 1ps

module CNN #(
    parameter DATA_WIDTH  = 8,
    parameter IN_CH       = 4,
    parameter OUT_CH      = 6,
    parameter SCALE_WIDTH = 8,
    parameter MAC_WIDTH   = 20,
    parameter LINE_WIDTH  = 128,
    parameter FEAT_DEPTH  = 32768,
    parameter FEAT_ADDR   = 15,
    parameter WM_DEPTH    = 65536,
    parameter WM_ADDR     = 16
) (
    input wire clk,
    input wire reset,
    input wire start,

    input wire                        pixel_valid_ext,
    input wire [DATA_WIDTH*IN_CH-1:0] pixel_in_ext,

    output wire                                frame_done,
    output wire                                pp_valid,
    output wire signed [DATA_WIDTH*OUT_CH-1:0] pp_out
);


    // ── control_unit ↔ memory_controller / conv_engine 연결 ──
    wire        [                  3:0] layer_id;
    wire        [                  7:0] row;
    wire        [                  7:0] col;
    wire        [                  4:0] in_pass;
    wire        [                  3:0] out_pass;

    wire                                mac_en;
    wire                                accum_clr;
    wire                                line_shift_en;
    wire                                maxpool_en;
    wire                                leaky_relu_en;
    wire        [                  1:0] kernel_mode;
    wire                                buf_sel;
    wire        [                  8:0] current_width;

    // conv_engine 입력
    wire                                pixel_valid_ce;
    wire        [ DATA_WIDTH*IN_CH-1:0] pixel_in_ce;

    // feature_mem 연결
    wire                                feat_wr;
    wire        [        FEAT_ADDR-1:0] feat_waddr;
    wire        [                  1:0] feat_wbank_sel;

    wire                                feat_rd;
    wire        [        FEAT_ADDR-1:0] feat_raddr;
    wire        [                  1:0] feat_rbank_sel;
    wire        [                 31:0] feat_pixel_out;

    // weight_rom 연결
    wire                                wm_rd;
    wire        [          WM_ADDR-1:0] wm_raddr;
    wire        [       DATA_WIDTH-1:0] wm_rdata;

    // scale / bias
    wire signed [      SCALE_WIDTH-1:0] scale_factor;
    wire signed [DATA_WIDTH*OUT_CH-1:0] bias;

    // ───────────────────────────────────────────────
    // control_unit
    // ───────────────────────────────────────────────
    control_unit u_control_unit (
        .clk  (clk),
        .reset(reset),
        .start(start),

        .layer_id(layer_id),
        .row     (row),
        .col     (col),
        .in_pass (in_pass),
        .out_pass(out_pass),

        .mac_en       (mac_en),
        .accum_clr    (accum_clr),
        .line_shift_en(line_shift_en),
        .maxpool_en   (maxpool_en),
        .leaky_relu_en(leaky_relu_en),
        .kernel_mode  (kernel_mode),
        .buf_sel      (buf_sel),
        .frame_done   (frame_done),
        .current_width(current_width)
    );

    // ───────────────────────────────────────────────
    // memory_controller
    // ───────────────────────────────────────────────
    memory_controller 
    // #(
    //     .DATA_WIDTH(DATA_WIDTH),
    //     .IN_CH     (IN_CH),
    //     .OUT_CH    (OUT_CH),
    //     .FEAT_ADDR (FEAT_ADDR),
    //     .WM_ADDR   (WM_ADDR)
    // ) 
    u_memory_controller (
        .clk  (clk),
        .reset(reset),

        .layer_id(layer_id),
        .row     (row),
        .col     (col),
        .in_pass (in_pass),
        .out_pass(out_pass),
        .mac_en  (mac_en),

        .pixel_valid_ext(pixel_valid_ext),
        .pixel_in_ext   (pixel_in_ext),

        .pp_valid(pp_valid),
        .pp_out  (pp_out),

        .pixel_valid_ce(pixel_valid_ce),
        .pixel_in_ce   (pixel_in_ce),

        .feat_wr       (feat_wr),
        .feat_waddr    (feat_waddr),
        .feat_wbank_sel(feat_wbank_sel),

        .feat_rd       (feat_rd),
        .feat_raddr    (feat_raddr),
        .feat_rbank_sel(feat_rbank_sel),
        .feat_pixel_out(feat_pixel_out),

        .wm_rd   (wm_rd),
        .wm_raddr(wm_raddr),

        .scale_factor(scale_factor),
        .bias        (bias)
    );

    // ───────────────────────────────────────────────
    // conv_engine
    // ───────────────────────────────────────────────
    conv_engine #(
        .DATA_WIDTH (DATA_WIDTH),
        .IN_CH      (IN_CH),
        .OUT_CH     (OUT_CH),
        .SCALE_WIDTH(SCALE_WIDTH),
        .MAC_WIDTH  (MAC_WIDTH),
        .LINE_WIDTH (LINE_WIDTH)
    ) u_conv_engine (
        .clk  (clk),
        .reset(reset),

        .mac_en(mac_en),
        .accum_clr(accum_clr),
        .pixel_valid(pixel_valid_ce),
        .pixel_in(pixel_in_ce),
        .leaky_relu_en(leaky_relu_en),
        .maxpool_en(maxpool_en),
        .kernel_mode(kernel_mode),
        .row(row[6:0]),  // conv_engine 포트 폭에 맞게 슬라이스
        .col(col[6:0]),

        .kernel(wm_rdata),

        .scale_factor(scale_factor),
        .bias        (bias),

        .pp_out  (pp_out),
        .pp_valid(pp_valid)
    );

    // ───────────────────────────────────────────────
    // weight_rom
    // ───────────────────────────────────────────────
    weight_rom #(
        .DEPTH     (WM_DEPTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(WM_ADDR),
        .HEX_FILE  ("weight.mem")
    ) u_weight_rom (
        .clk  (clk),
        .rd   (wm_rd),
        .raddr(wm_raddr),
        .rdata(wm_rdata)
    );

    // ───────────────────────────────────────────────
    // feature_mem
    // ───────────────────────────────────────────────
    feature_mem #(
        .DEPTH     (FEAT_DEPTH),
        .ADDR_WIDTH(FEAT_ADDR)
    ) u_feature_mem (
        .clk(clk),

        .wr   (feat_wr),
        .waddr(feat_waddr),
        .wdata(pp_out),      // 6ch 결과 통째로 write [file:9]

        .rd       (feat_rd),
        .raddr    (feat_raddr),
        .bank_sel (feat_rbank_sel),
        .pixel_out(feat_pixel_out)
    );

endmodule
