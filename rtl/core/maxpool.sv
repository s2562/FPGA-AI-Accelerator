module maxpool #(
    parameter DATA_WIDTH = 8,
    parameter OUT_CH     = 6,
    parameter MAX_COL    = 256  // 입력 이미지의 가로 픽셀 수
) (
    input  logic                                clk,
    input  logic                                reset,
    input  logic                                valid_in,
    input  logic                                maxpool_en,
    input  logic        [                  7:0] row,
    input  logic        [                  7:0] col,
    input  logic signed [DATA_WIDTH*OUT_CH-1:0] data_in,
    output logic signed [DATA_WIDTH*OUT_CH-1:0] data_out,
    output logic                                valid_out
);

    // ───────────────────────────────────────────────────────────
    // 1. 수평(Horizontal) Max 연산 (col과 col+1 비교)
    // ───────────────────────────────────────────────────────────
    logic signed [DATA_WIDTH*OUT_CH-1:0] reg_even_col;
    logic signed [DATA_WIDTH*OUT_CH-1:0] max_h;

    always_ff @(posedge clk) begin
        if (valid_in && maxpool_en) begin
            if (col[0] == 1'b0) begin
                // 짝수 열(col) 데이터 임시 저장
                reg_even_col <= data_in;
            end
        end
    end

    always_comb begin
        // 홀수 열(col)이 들어왔을 때, 방금 들어온 값과 짝수 열 값을 채널별로 병렬 비교
        for (int c = 0; c < OUT_CH; c++) begin
            logic signed [DATA_WIDTH-1:0] cur_val, prev_val;
            cur_val = data_in[c*DATA_WIDTH+:DATA_WIDTH];
            prev_val = reg_even_col[c*DATA_WIDTH+:DATA_WIDTH];

            max_h[c*DATA_WIDTH +: DATA_WIDTH] = (cur_val > prev_val) ? cur_val : prev_val;
        end
    end

    // ───────────────────────────────────────────────────────────
    // 2. Line Buffer (윗줄의 max_h 결과 저장용)
    // ───────────────────────────────────────────────────────────
    // 깊이: 가로 픽셀의 절반 (stride 2이므로)
    logic [DATA_WIDTH*OUT_CH-1:0] line_buffer[0:(MAX_COL/2)-1];
    logic [6:0] lb_addr;

    assign lb_addr = col[7:1]; // 2픽셀당 1개씩 저장/읽기 (Stride 2 인덱싱)

    logic signed [DATA_WIDTH*OUT_CH-1:0] lb_rdata;
    assign lb_rdata = line_buffer[lb_addr];

    always_ff @(posedge clk) begin
        // 짝수 행(row)이면서, 홀수 열(col) 계산이 끝났을 때 버퍼에 기록
        if (valid_in && maxpool_en && row[0] == 1'b0 && col[0] == 1'b1) begin
            line_buffer[lb_addr] <= max_h;
        end
    end

    // ───────────────────────────────────────────────────────────
    // 3. 최종 수직(Vertical) Max 연산 및 출력
    // ───────────────────────────────────────────────────────────
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            data_out  <= '0;
            valid_out <= 1'b0;
        end else if (valid_in && maxpool_en) begin
            // 2x2 윈도우의 마지막 픽셀(홀수 row, 홀수 col)이 들어왔을 때 최종 비교
            if (row[0] == 1'b1 && col[0] == 1'b1) begin
                for (int c = 0; c < OUT_CH; c++) begin
                    logic signed [DATA_WIDTH-1:0] top_val, bot_val;
                    top_val = lb_rdata[c*DATA_WIDTH +: DATA_WIDTH]; // 윗줄에서 구한 max
                    bot_val = max_h[c*DATA_WIDTH +: DATA_WIDTH];    // 아랫줄에서 방금 구한 max

                    data_out[c*DATA_WIDTH +: DATA_WIDTH] <= (bot_val > top_val) ? bot_val : top_val;
                end
                valid_out <= 1'b1;  // 최종 결과 출력!
            end else begin
                valid_out <= 1'b0; // 윈도우가 완성되지 않았을 때는 0
            end
        end else if (valid_in && !maxpool_en) begin
            // Maxpool Bypass (L3 레이어 등)
            data_out  <= data_in;
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
