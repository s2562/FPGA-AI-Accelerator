`timescale 1ns / 1ps

module mac_array #(
    parameter DATA_WIDTH  = 8,
    parameter IN_CH       = 4,
    parameter OUT_CH      = 6,
    parameter ACCUM_WIDTH = 25   // 20(Stage2) + 5(log2(max_in_pass=24)) 최악 기준
) (
    input  logic                                        clk,
    input  logic                                        reset,

    // Control Unit 신호
    input  logic                                        mac_en,
    input  logic                                        accum_clr,      // in_pass == 0 일 때 High (새 픽셀 시작)
    input  logic                                        in_pass_done,   // 마지막 in_pass 일 때 High
    input  logic [1:0]                                  kernel_mode,    // 2'b00: 3x3 / 2'b01: 1x1

    // 픽셀 좌표 (zero-padding mask 계산용)
    input  logic [7:0]                                  row,
    input  logic [7:0]                                  col,
    input  logic [8:0]                                  current_width,

    // 입력 데이터 (window_reg에서)
    input  logic                                        window_valid,
    input  logic [DATA_WIDTH*IN_CH*9 - 1:0]             window_data,

    // 가중치 (weight_rom에서)
    input  logic signed [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] kernel,

    // 출력
    output logic signed [ACCUM_WIDTH*OUT_CH - 1:0]      mac_out,
    output logic                                        mac_valid
);

    // ============================================================
    // Internal Signals
    // ============================================================
    logic signed [8:0] center_row;
    logic signed [8:0] center_col;
    logic signed [9:0] curr_w;

    logic [8:0] pad_mask;

    logic signed [15:0] mul_reg     [0:OUT_CH-1][0:IN_CH-1][0:8];
    logic signed [17:0] sum_spatial [0:OUT_CH-1][0:IN_CH-1];
    logic signed [19:0] sum_final   [0:OUT_CH-1];
    logic signed [ACCUM_WIDTH-1:0] accum_out [0:OUT_CH-1];

    // ============================================================
    // Pipeline Control Tokens (4비트 Shift Register)
    //   Bit[0]: 입력단  (Stage 0에 인가되는 시점)
    //   Bit[1]: Stage 1 입력 시점
    //   Bit[2]: Stage 2 입력 시점  <- accum_clr, valid가 Stage3로 들어갈 때 기준
    //   Bit[3]: Stage 3 출력 시점  <- mac_valid 기준
    // ============================================================
    logic [3:0] p_valid;  // window_valid 파이프라인 토큰
    logic [3:0] p_clr;    // accum_clr   파이프라인 토큰
    logic [3:0] p_last;   // in_pass_done 파이프라인 토큰

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            p_valid <= 4'b0000;
            p_clr   <= 4'b0000;
            p_last  <= 4'b0000;
        end else if (mac_en) begin
            p_valid <= {p_valid[2:0], window_valid};
            p_clr   <= {p_clr[2:0],   accum_clr};
            p_last  <= {p_last[2:0],  (window_valid && in_pass_done)};
        end
    end

    // ============================================================
    // Zero-Padding Mask
    // conv 중심 좌표: (row-1, col-1)
    // ============================================================

    logic [7:0] row_d0, row_d1;
    logic [7:0] col_d0, col_d1;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            row_d0 <= '0;  row_d1 <= '0;
            col_d0 <= '0;  col_d1 <= '0;
        end else if (mac_en) begin
            row_d0 <= row;      // 1클럭 지연
            row_d1 <= row_d0;   // 2클럭 지연
            col_d0 <= col;
            col_d1 <= col_d0;
        end
    end

    assign center_row = $signed({1'b0, row_d1}) - 9'sd1;
    assign center_col = $signed({1'b0, col_d1}) - 9'sd1;
    assign curr_w = $signed({1'b0, current_width});

    always_comb begin
        pad_mask[0] = ((center_row-9'sd1) >= 0) && ((center_row-9'sd1) < curr_w) &&
                      ((center_col-9'sd1) >= 0) && ((center_col-9'sd1) < curr_w);
        pad_mask[1] = ((center_row-9'sd1) >= 0) && ((center_row-9'sd1) < curr_w) &&
                      (center_col          >= 0) && (center_col          < curr_w);
        pad_mask[2] = ((center_row-9'sd1) >= 0) && ((center_row-9'sd1) < curr_w) &&
                      ((center_col+9'sd1) >= 0) && ((center_col+9'sd1) < curr_w);
        pad_mask[3] = (center_row          >= 0) && (center_row          < curr_w) &&
                      ((center_col-9'sd1) >= 0) && ((center_col-9'sd1) < curr_w);
        pad_mask[4] = (center_row          >= 0) && (center_row          < curr_w) &&
                      (center_col          >= 0) && (center_col          < curr_w);
        pad_mask[5] = (center_row          >= 0) && (center_row          < curr_w) &&
                      ((center_col+9'sd1) >= 0) && ((center_col+9'sd1) < curr_w);
        pad_mask[6] = ((center_row+9'sd1) >= 0) && ((center_row+9'sd1) < curr_w) &&
                      ((center_col-9'sd1) >= 0) && ((center_col-9'sd1) < curr_w);
        pad_mask[7] = ((center_row+9'sd1) >= 0) && ((center_row+9'sd1) < curr_w) &&
                      (center_col          >= 0) && (center_col          < curr_w);
        pad_mask[8] = ((center_row+9'sd1) >= 0) && ((center_row+9'sd1) < curr_w) &&
                      ((center_col+9'sd1) >= 0) && ((center_col+9'sd1) < curr_w);
    end

    // ============================================================
    // Stage 0: Parallel Multiplication (1 클럭)
    // [수정] 불필요한 p_clr[0] 0-초기화 로직 제거 (덮어쓰기 방식으로 변경)
    // ============================================================
    genvar out_c, in_c, i;
    generate
        for (out_c = 0; out_c < OUT_CH; out_c++) begin : gen_mult_out
            for (in_c = 0; in_c < IN_CH; in_c++) begin : gen_mult_in
                for (i = 0; i < 9; i++) begin : gen_mult_unit
                    localparam integer WIN_IDX = i * IN_CH + in_c;
                    localparam integer KRN_IDX = out_c * (IN_CH * 9) + in_c * 9 + i;

                    always_ff @(posedge clk or posedge reset) begin
                        if (reset) begin
                            mul_reg[out_c][in_c][i] <= 16'sd0;
                        end else if (mac_en && window_valid) begin
                            if (kernel_mode == 2'b01) begin
                                // 1x1: center tap(i==4)만 유효
                                mul_reg[out_c][in_c][i] <= (i == 4) ?
                                    ($signed(window_data[WIN_IDX*DATA_WIDTH +: DATA_WIDTH]) *
                                     $signed(kernel[KRN_IDX*DATA_WIDTH +: DATA_WIDTH])) :
                                    16'sd0;
                            end else begin
                                // 3x3: zero-padding mask 적용
                                mul_reg[out_c][in_c][i] <= pad_mask[i] ?
                                    ($signed(window_data[WIN_IDX*DATA_WIDTH +: DATA_WIDTH]) *
                                     $signed(kernel[KRN_IDX*DATA_WIDTH +: DATA_WIDTH])) :
                                    16'sd0;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // ============================================================
    // Stage 1: Spatial Sum (1 클럭) — 9개 커널 위치 합산
    // [수정] 불필요한 p_clr[1] 0-초기화 로직 제거
    // ============================================================
    genvar out_s1, in_s1;
    generate
        for (out_s1 = 0; out_s1 < OUT_CH; out_s1++) begin : gen_s1_out
            for (in_s1 = 0; in_s1 < IN_CH; in_s1++) begin : gen_s1_in
                always_ff @(posedge clk or posedge reset) begin
                    if (reset) begin
                        sum_spatial[out_s1][in_s1] <= 18'sd0;
                    end else if (mac_en && p_valid[0]) begin
                        sum_spatial[out_s1][in_s1] <=
                              $signed(mul_reg[out_s1][in_s1][0])
                            + $signed(mul_reg[out_s1][in_s1][1])
                            + $signed(mul_reg[out_s1][in_s1][2])
                            + $signed(mul_reg[out_s1][in_s1][3])
                            + $signed(mul_reg[out_s1][in_s1][4])
                            + $signed(mul_reg[out_s1][in_s1][5])
                            + $signed(mul_reg[out_s1][in_s1][6])
                            + $signed(mul_reg[out_s1][in_s1][7])
                            + $signed(mul_reg[out_s1][in_s1][8]);
                    end
                end
            end
        end
    endgenerate

    // ============================================================
    // Stage 2: Channel Reduction (1 클럭) — IN_CH개 채널 합산
    // [수정] 불필요한 p_clr[2] 0-초기화 로직 제거
    // ============================================================
    genvar out_s2;
    generate
        for (out_s2 = 0; out_s2 < OUT_CH; out_s2++) begin : gen_s2_out
            always_ff @(posedge clk or posedge reset) begin
                if (reset) begin
                    sum_final[out_s2] <= 20'sd0;
                end else if (mac_en && p_valid[1]) begin
                    sum_final[out_s2] <=
                          $signed(sum_spatial[out_s2][0])
                        + $signed(sum_spatial[out_s2][1])
                        + $signed(sum_spatial[out_s2][2])
                        + $signed(sum_spatial[out_s2][3]);
                end
            end
        end
    endgenerate

    // ============================================================
    // Stage 3: Temporal Accumulation (1 클럭) — in_pass 방향 누산
    // 🌟 여기는 p_clr[2]에 의한 분기 유지 (덮어쓰기 vs 누적)
    // ============================================================
    genvar out_s3;
    generate
        for (out_s3 = 0; out_s3 < OUT_CH; out_s3++) begin : gen_s3_out
            always_ff @(posedge clk or posedge reset) begin
                if (reset) begin
                    accum_out[out_s3] <= '0;
                end else if (mac_en && p_valid[2]) begin
                    if (p_clr[2]) begin
                        // 새 픽셀 첫 in_pass (accum_clr=1 도달 시점): 이전 누산값 버리고 새 값으로 덮어쓰기(=)
                        accum_out[out_s3] <= ACCUM_WIDTH'($signed(sum_final[out_s3]));
                    end else begin
                        // 동일 픽셀 다음 in_pass: 계속 누산(+=)
                        accum_out[out_s3] <= accum_out[out_s3]
                                           + ACCUM_WIDTH'($signed(sum_final[out_s3]));
                    end
                end
            end
        end
    endgenerate

    // ============================================================
    // Output
    // ============================================================
    assign mac_valid = p_last[3];

    genvar out_idx;
    generate
        for (out_idx = 0; out_idx < OUT_CH; out_idx++) begin : gen_output_map
            assign mac_out[out_idx*ACCUM_WIDTH +: ACCUM_WIDTH] = accum_out[out_idx];
        end
    endgenerate

endmodule