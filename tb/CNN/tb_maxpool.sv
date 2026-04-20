`timescale 1ns / 1ps

module tb_maxpool ();

    parameter DATA_WIDTH = 8;
    parameter OUT_CH = 6;
    parameter MAX_COL = 256;
    parameter MAX_ROW = 256;

    logic clk;
    logic reset;
    logic valid_in;
    logic maxpool_en;
    logic [7:0] row, col;  // TB에서 생성할 카운터
    logic signed [DATA_WIDTH*OUT_CH-1:0] data_in;

    wire signed [DATA_WIDTH*OUT_CH-1:0] data_out;
    wire valid_out;

    // 1. 모듈 인스턴스화
    maxpool #(
        .DATA_WIDTH(DATA_WIDTH),
        .OUT_CH(OUT_CH),
        .MAX_COL(MAX_COL)
    ) u_maxpool (
        .clk(clk),
        .reset(reset),
        .valid_in(valid_in),
        .maxpool_en(maxpool_en),
        .row(row),
        .col(col),
        .data_in(data_in),
        .data_out(data_out),
        .valid_out(valid_out)
    );

    // 2. 클록 생성
    always #5 clk = ~clk;

    // 3. 컨트롤 유닛 모사: Row/Col 카운터 로직
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            col <= 8'd0;
            row <= 8'd0;
        end else if (valid_in) begin
            if (col == MAX_COL - 1) begin
                col <= 8'd0;
                if (row == MAX_ROW - 1) row <= 8'd0;
                else row <= row + 8'd1;
            end else begin
                col <= col + 8'd1;
            end
        end
    end

    // ---------------------------------------------------------
    // 4. 테스트 데이터 주입 (기존과 동일, 하단부만 추가)
    // ---------------------------------------------------------
    initial begin
        clk = 0;
        reset = 1;
        valid_in = 0;
        maxpool_en = 1;
        data_in = 0;
        #25 reset = 0;

        repeat (6) begin
            for (int i = 0; i < MAX_COL; i++) begin
                @(posedge clk);
                valid_in = 1;
                #1;
                case (i % 6)
                    'd0: data_in[7:0] = 8'd0;
                    'd1: data_in[7:0] = 8'd10;
                    'd2: data_in[7:0] = 8'd20;
                    'd3: data_in[7:0] = 8'd30;
                    'd4: data_in[7:0] = 8'd40;
                    'd5: data_in[7:0] = 8'd60;
                endcase
            end
            @(posedge clk);
            valid_in = 0;
            repeat (10) @(posedge clk);
        end

        // 시뮬레이션 종료 전, 전체 결과를 한눈에 보는 Task 호출
        print_summary();

        #100;
        $finish;
    end

    // ---------------------------------------------------------
    // 5. 행렬 모니터링 로직 (전체 버퍼링 & 시각화)
    // ---------------------------------------------------------
    // TB용 전체 이미지 메모리 할당
    logic signed [DATA_WIDTH-1:0] full_in_img[0:MAX_ROW-1][0:MAX_COL-1];
    logic signed [DATA_WIDTH-1:0] full_out_img [0:(MAX_ROW/2)-1][0:(MAX_COL/2)-1];

    logic [7:0] row_q, col_q;
    always_ff @(posedge clk) begin
        row_q <= row;
        col_q <= col;
    end
    // (1) 입력 데이터 전체 History 저장
    always_ff @(posedge clk) begin
        if (valid_in && maxpool_en) begin
            full_in_img[row][col] <= data_in[0*DATA_WIDTH+:DATA_WIDTH];
        end
    end
    // (2) 좌표 기반 출력 데이터 저장 및 로그 출력
    always_ff @(posedge clk) begin
        if (valid_out) begin
            // 1. 출력 배열의 좌표 계산 (Stride 2를 반영하여 2로 나눈 값)
            // 인덱스를 미리 변수에 할당하면 display 문이 훨씬 깔끔해집니다.
            automatic int out_y = row_q[7:1];
            automatic int out_x = col_q[7:1];

            // 2. 결과 배열에 저장
            full_out_img[out_y][out_x] <= data_out[7:0];

            // 3. 실시간 2x2 윈도우 매칭 로그 출력
            $display("\n[RESULT] @Time: %0t ps | Out Coord: (%0d, %0d)", $time,
                     out_y, out_x);
            $display("-------------------------------------------");
            $display("  Input Window (2x2)       |  Output");

            // row_q, col_q가 윈도우의 마지막(오른쪽 아래) 좌표이므로 
            // 2x2 영역은 (row_q-1, col_q-1)부터 (row_q, col_q)까지입니다.
            $display("  %3d  %3d                |",
                     full_in_img[row_q-1][col_q-1],
                     full_in_img[row_q-1][col_q]);

            $display(
                "  %3d  %3d (Last Pixel)   |  %3d", full_in_img[row_q][col_q-1],
                full_in_img[row_q][col_q],  // 현재 입력된 마지막 픽셀
                data_out[7:0]);
            $display("-------------------------------------------");
        end
    end

    // ---------------------------------------------------------
    // 6. 전체 행렬 요약 출력 Task
    // ---------------------------------------------------------
    task print_summary();
        $display("\n=======================================================");
        $display("          MAXPOOL FULL RESULT SUMMARY (Ch 0)           ");
        $display("=======================================================\n");

        $display("--- INPUT MATRIX ---");
        // MAX_COL이 256이라 터미널이 터지는 걸 방지하기 위해 16열까지만 출력
        for (
            int r = 0; r < 6; r++
        ) begin  // 주입한 데이터가 6행이므로
            for (int c = 0; c < 16; c++) begin
                $write("%4d ", full_in_img[r][c]);
            end
            $display(" ... ");
        end

        $display("\n--- OUTPUT MATRIX ---");
        // 출력은 가로세로 절반(Stride 2)이므로 3행 8열 출력
        for (int r = 0; r < 3; r++) begin
            for (int c = 0; c < 8; c++) begin
                $write("%4d ", full_out_img[r][c]);
            end
            $display(" ... ");
        end
        $display("=======================================================\n");
    endtask

endmodule
