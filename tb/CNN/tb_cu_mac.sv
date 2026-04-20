`timescale 1ns / 1ps

module tb_cu_mac;

    // ============================================================
    // Parameters
    // ============================================================
    localparam DATA_WIDTH = 8;
    localparam IN_CH = 4;
    localparam OUT_CH = 6;
    localparam ACCUM_WIDTH = 25;

    // ============================================================
    // CU 포트
    // ============================================================
    logic clk, reset, start;

    logic [3:0] layer_id;
    logic [7:0] row, col;
    logic [4:0] in_pass;
    logic [3:0] out_pass;

    logic       mac_en;
    logic       accum_clr;
    logic       in_pass_done;  // ← CU에 포트 추가 후 연결
    logic       line_shift_en;
    logic       maxpool_en;
    logic       leaky_relu_en;
    logic [1:0] kernel_mode;
    logic       buf_sel;
    logic       frame_done;
    logic [8:0] current_width;

    // ============================================================
    // mac_array 전용 추가 신호
    // ============================================================
    // window_valid: CU에 없으므로 TB에서 mac_en과 동기화
    logic       window_valid;
    assign window_valid = mac_en;  // 데이터 항상 준비됐다고 가정

    logic        [       DATA_WIDTH*IN_CH*9-1:0] window_data;
    logic        [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] kernel_w;

    logic signed [       ACCUM_WIDTH*OUT_CH-1:0] mac_out;
    logic                                        mac_valid;

    // ============================================================
    // DUT 인스턴스
    // ============================================================
    control_unit cu (
        .clk          (clk),
        .reset        (reset),
        .start        (start),
        .layer_id     (layer_id),
        .row          (row),
        .col          (col),
        .in_pass      (in_pass),
        .out_pass     (out_pass),
        .mac_en       (mac_en),
        .accum_clr    (accum_clr),
        .in_pass_done (in_pass_done),   // ← 추가된 포트
        .line_shift_en(line_shift_en),
        .maxpool_en   (maxpool_en),
        .leaky_relu_en(leaky_relu_en),
        .kernel_mode  (kernel_mode),
        .buf_sel      (buf_sel),
        .frame_done   (frame_done),
        .current_width(current_width)
    );

    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .IN_CH      (IN_CH),
        .OUT_CH     (OUT_CH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) mac (
        .clk          (clk),
        .reset        (reset),
        .mac_en       (mac_en),
        .accum_clr    (accum_clr),
        .in_pass_done (in_pass_done),
        .kernel_mode  (kernel_mode),
        .row          (row),
        .col          (col),
        .current_width(current_width),
        .window_valid (window_valid),
        .window_data  (window_data),
        .kernel       (kernel_w),
        .mac_out      (mac_out),
        .mac_valid    (mac_valid)
    );

    // ============================================================
    // 클럭
    // ============================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // 고정 테스트 데이터 (win=1, ker=1 — 기대값 계산 용이)
    // ============================================================
    initial begin
        window_data = '0;
        kernel_w    = '0;
        for (int i = 0; i < IN_CH * 9; i++)
        window_data[i*DATA_WIDTH+:DATA_WIDTH] = 8'd1;
        for (int i = 0; i < OUT_CH * IN_CH * 9; i++)
        kernel_w[i*DATA_WIDTH+:DATA_WIDTH] = 8'd1;
    end

    // ============================================================
    // 파이프라인 트래커 (4클럭 지연)
    // ============================================================
    logic [7:0] r_pipe  [0:3];
    logic [7:0] c_pipe  [0:3];
    logic [4:0] ip_pipe [0:3];
    logic [3:0] op_pipe [0:3];
    logic [3:0] lid_pipe[0:3];
    logic [1:0] km_pipe [0:3];

    always_ff @(posedge clk) begin
        if (mac_en) begin
            r_pipe[0]   <= row;
            r_pipe[1]   <= r_pipe[0];
            r_pipe[2]   <= r_pipe[1];
            r_pipe[3]   <= r_pipe[2];

            c_pipe[0]   <= col;
            c_pipe[1]   <= c_pipe[0];
            c_pipe[2]   <= c_pipe[1];
            c_pipe[3]   <= c_pipe[2];

            ip_pipe[0]  <= in_pass;
            ip_pipe[1]  <= ip_pipe[0];
            ip_pipe[2]  <= ip_pipe[1];
            ip_pipe[3]  <= ip_pipe[2];

            op_pipe[0]  <= out_pass;
            op_pipe[1]  <= op_pipe[0];
            op_pipe[2]  <= op_pipe[1];
            op_pipe[3]  <= op_pipe[2];

            lid_pipe[0] <= layer_id;
            lid_pipe[1] <= lid_pipe[0];
            lid_pipe[2] <= lid_pipe[1];
            lid_pipe[3] <= lid_pipe[2];

            km_pipe[0]  <= kernel_mode;
            km_pipe[1]  <= km_pipe[0];
            km_pipe[2]  <= km_pipe[1];
            km_pipe[3]  <= km_pipe[2];
        end
    end

    // ============================================================
    // 기대값 함수
    // ============================================================
    function automatic int expected_val(
        input logic [1:0] kmode, input logic [7:0] r, input logic [7:0] c,
        input logic [8:0] cw,
        input int         ip_count   // 실제 in_pass 수 (max_in_pass + 1)
  );
        automatic int tap_count = 0;
        automatic int cr = int'(r) - 1;
        automatic int cc = int'(c) - 1;
        automatic int w = int'(cw);

        if (kmode == 2'b01) begin
            // 1x1: 패딩 무관, tap=1
            tap_count = 1;
        end else begin
            // 3x3: 유효 픽셀 수 계산
            for (int dr = -1; dr <= 1; dr++) begin
                for (int dc = -1; dc <= 1; dc++) begin
                    if ((cr+dr) >= 0 && (cr+dr) < w &&
              (cc+dc) >= 0 && (cc+dc) < w)
                        tap_count++;
                end
            end
        end
        return tap_count * IN_CH * ip_count;
    endfunction

    // ============================================================
    // 모니터 + 자동 검증
    // ============================================================
    int pass_cnt, fail_cnt;

    always_ff @(negedge clk) begin
        if (mac_valid) begin
            automatic
            int
            exp = expected_val(
                km_pipe[3],
                r_pipe[3],
                c_pipe[3],
                current_width,
                int'(ip_pipe[3]) + 1  // in_pass는 0-base이므로 +1
            );
            automatic
            int
            got = int'($signed(
                mac_out[0*ACCUM_WIDTH+:ACCUM_WIDTH]
            ));
            automatic string result = (got == exp) ? "PASS" : "FAIL <<<";

            $display("[L%0d|%s|op=%0d] R:%0d C:%0d | CH0=%4d (exp=%4d) %s",
                     lid_pipe[3], (km_pipe[3] == 2'b00) ? "3x3" : "1x1",
                     op_pipe[3], r_pipe[3], c_pipe[3], got, exp, result);

            if (got == exp) pass_cnt++;
            else fail_cnt++;
        end
    end

    // ============================================================
    // 메인 시퀀스
    // ============================================================
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        reset = 1;
        start = 0;
        #20;
        reset = 0;
        #10;

        // CU 시작
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // frame_done 대기 (타임아웃 포함)
        fork
            begin
                wait (frame_done == 1'b1);
                // 파이프라인 드레인
                repeat (8) @(posedge clk);
            end
            begin
                // 타임아웃: 실제 전체 클럭 수보다 넉넉하게
                // L0만 해도 256×256×1 = 65536 클럭이므로 현실적으로
                // SIM 목적상 L0만 돌리거나 작은 해상도로 줄이는 것을 권장
                #5_000_000;
                $display("TIMEOUT — frame_done이 오지 않았습니다");
                $finish;
            end
        join_any
        disable fork;

        $display("\n=============================");
        $display("✅ PASS: %0d  ❌ FAIL: %0d", pass_cnt, fail_cnt);
        $display("=============================\n");
        $finish;
    end

endmodule
