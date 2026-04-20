`timescale 1ns / 1ps

module control_unit (
    input logic clk,
    input logic reset,
    input logic start,

    output logic [3:0] layer_id,
    output logic [7:0] row,
    output logic [7:0] col,
    output logic [4:0] in_pass,
    output logic [3:0] out_pass,

    output logic       line_shift_en,
    output logic       mac_en,
    output logic       accum_clr,
    output logic       in_pass_done,
    output logic       maxpool_en,
    output logic       leaky_relu_en,
    output logic [1:0] kernel_mode,
    output logic       buf_sel,
    output logic       frame_done,
    output logic [8:0] current_width
);

    // ============================================================
    // State Encoding
    // ============================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_L0,
        S_L1,
        S_L2,
        S_L3,
        S_L4A,
        S_L4B,
        S_L4C,
        S_HEAD,
        S_DONE
    } state_t;

    state_t state, next_state;

    // ============================================================
    // LUT Entry 구조 (packed)
    // [  3:0] max_out_pass
    // [ 11:4] max_row
    // [19:12] max_col
    // [24:20] max_in_pass
    // [28:25] layer_id
    // [29]    line_shift_en
    // [30]    maxpool_en_base  (in_pass_done 조건은 별도 AND)
    // [31]    leaky_relu_base  (in_pass_done 조건은 별도 AND)
    // [33:32] kernel_mode
    // [34]    buf_sel
    // ============================================================
    // 총 35비트 packed LUT
    localparam int LUT_W = 35;

    // LUT 인덱스: state[3:0] (0=IDLE, 1=L0 ... 8=HEAD, 9=DONE)
    logic [LUT_W-1:0] layer_lut[0:9];

    // Format: {buf_sel, kernel_mode, leaky_base, maxpool_base,
    //          line_shift, layer_id, max_in_pass, max_col, max_row, max_out_pass}
    initial begin
        //     bs km  lr mp  ls  lid  mip      mcol     mrow    mop
        layer_lut[0] = {
            1'b0, 2'b00, 1'b0, 1'b0, 1'b0, 4'd0, 5'd0, 8'd0, 8'd0, 4'd0
        };  // IDLE
        layer_lut[1] = {
            1'b0, 2'b00, 1'b1, 1'b1, 1'b1, 4'd0, 5'd0, 8'd255, 8'd255, 4'd1
        };  // L0
        layer_lut[2] = {
            1'b1, 2'b00, 1'b1, 1'b1, 1'b1, 4'd1, 5'd2, 8'd127, 8'd127, 4'd3
        };  // L1
        layer_lut[3] = {
            1'b0, 2'b00, 1'b1, 1'b1, 1'b1, 4'd2, 5'd5, 8'd63, 8'd63, 4'd7
        };  // L2
        layer_lut[4] = {
            1'b1, 2'b00, 1'b1, 1'b0, 1'b1, 4'd3, 5'd11, 8'd31, 8'd31, 4'd15
        };  // L3
        layer_lut[5] = {
            1'b0, 2'b01, 1'b1, 1'b0, 1'b0, 4'd4, 5'd23, 8'd31, 8'd31, 4'd7
        };  // L4A
        layer_lut[6] = {
            1'b1, 2'b00, 1'b1, 1'b0, 1'b1, 4'd5, 5'd11, 8'd31, 8'd31, 4'd7
        };  // L4B
        layer_lut[7] = {
            1'b0, 2'b01, 1'b1, 1'b0, 1'b0, 4'd6, 5'd11, 8'd31, 8'd31, 4'd15
        };  // L4C
        layer_lut[8] = {
            1'b1, 2'b01, 1'b0, 1'b0, 1'b0, 4'd7, 5'd23, 8'd31, 8'd31, 4'd2
        };  // HEAD
        layer_lut[9] = {
            1'b0, 2'b00, 1'b0, 1'b0, 1'b0, 4'd0, 5'd0, 8'd0, 8'd0, 4'd0
        };  // DONE
    end

    // ============================================================
    // LUT 필드 언팩
    // ============================================================
    logic [LUT_W-1:0] cur_lut;
    logic [3:0] max_out_pass;
    logic [7:0] max_row, max_col;
    logic [4:0] max_in_pass;
    logic [3:0] lut_layer_id;
    logic       lut_line_shift;
    logic       lut_maxpool_base;
    logic       lut_leaky_base;
    logic [1:0] lut_kernel_mode;
    logic       lut_buf_sel;

    assign cur_lut          = layer_lut[state];
    assign max_out_pass     = cur_lut[3:0];
    assign max_row          = cur_lut[11:4];
    assign max_col          = cur_lut[19:12];
    assign max_in_pass      = cur_lut[24:20];
    assign lut_layer_id     = cur_lut[28:25];
    assign lut_line_shift   = cur_lut[29];
    assign lut_maxpool_base = cur_lut[30];
    assign lut_leaky_base   = cur_lut[31];
    assign lut_kernel_mode  = cur_lut[33:32];
    assign lut_buf_sel      = cur_lut[34];

    assign current_width    = {1'b0, max_col} + 9'd1;

    // ============================================================
    // 카운터 완료 조건
    // ============================================================
    assign in_pass_done     = (in_pass == max_in_pass);
    logic col_done, row_done, out_pass_done;
    assign col_done      = (col == max_col) && in_pass_done;
    assign row_done      = (row == max_row) && col_done;
    assign out_pass_done = (out_pass == max_out_pass) && row_done;

    // ============================================================
    // 제어 신호 출력 (LUT + 조건 AND)
    // ============================================================
    logic active;  // IDLE, DONE이 아닌 상태
    assign active        = (state != S_IDLE) && (state != S_DONE);

    assign layer_id      = lut_layer_id;
    assign mac_en        = active;
    assign accum_clr     = active && (in_pass == '0);
    assign line_shift_en = lut_line_shift;
    assign maxpool_en    = active && lut_maxpool_base && in_pass_done;
    assign leaky_relu_en = active && lut_leaky_base && in_pass_done;
    assign kernel_mode   = lut_kernel_mode;
    assign buf_sel       = lut_buf_sel;
    assign frame_done    = (state == S_DONE);

    // ============================================================
    // 상태 전이 (next_state)
    // ============================================================
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE:  if (start) next_state = S_L0;
            S_L0:    if (out_pass_done) next_state = S_L1;
            S_L1:    if (out_pass_done) next_state = S_L2;
            S_L2:    if (out_pass_done) next_state = S_L3;
            S_L3:    if (out_pass_done) next_state = S_L4A;
            S_L4A:   if (out_pass_done) next_state = S_L4B;
            S_L4B:   if (out_pass_done) next_state = S_L4C;
            S_L4C:   if (out_pass_done) next_state = S_HEAD;
            S_HEAD:  if (out_pass_done) next_state = S_DONE;
            S_DONE:  next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    // ============================================================
    // 순차 카운터
    // ============================================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= S_IDLE;
            row      <= '0;
            col      <= '0;
            in_pass  <= '0;
            out_pass <= '0;
        end else begin
            state <= next_state;

            if (state == S_IDLE || state == S_DONE) begin
                row      <= '0;
                col      <= '0;
                in_pass  <= '0;
                out_pass <= '0;
            end else begin
                if (in_pass_done) begin
                    in_pass <= '0;
                    if (col_done) begin
                        col <= '0;
                        if (row_done) begin
                            row <= '0;
                            if (!out_pass_done) out_pass <= out_pass + 1'b1;
                            else out_pass <= '0;
                        end else row <= row + 1'b1;
                    end else col <= col + 1'b1;
                end else in_pass <= in_pass + 1'b1;
            end
        end
    end

endmodule
