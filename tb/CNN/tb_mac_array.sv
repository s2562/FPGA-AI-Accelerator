`timescale 1ns / 1ps

module tb_mac_array;

    localparam DATA_WIDTH = 8;
    localparam IN_CH = 4;
    localparam OUT_CH = 6;
    localparam ACCUM_WIDTH = 25;
    localparam PAD_DELAY = 2;  // mac_array 내부 row/col 지연
    localparam PIPE_DEPTH = PAD_DELAY + 4;  // = 6

    logic clk, reset, mac_en;
    logic accum_clr, in_pass_done, window_valid;
    logic [1:0] kernel_mode;
    logic [7:0] row, col;
    logic        [                          8:0] current_width;
    logic        [       DATA_WIDTH*IN_CH*9-1:0] window_data;
    logic        [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] kernel_w;
    logic signed [       ACCUM_WIDTH*OUT_CH-1:0] mac_out;
    logic                                        mac_valid;

    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .IN_CH      (IN_CH),
        .OUT_CH     (OUT_CH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) dut (
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

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // Scoreboard Queue
    // ============================================================
    typedef struct {
        int row;
        int col;
        int exp[0:OUT_CH-1];  // 채널별 기대값
        logic [1:0] kmode;
        string label;
    } sb_entry_t;

    sb_entry_t sb_queue[$];  // FIFO

    int pass_cnt = 0;
    int fail_cnt = 0;

    // ============================================================
    // 파이프라인 트래커 — PIPE_DEPTH단
    // ============================================================
    logic [7:0] r_pipe[0:PIPE_DEPTH-1];
    logic [7:0] c_pipe[0:PIPE_DEPTH-1];
    logic [1:0] k_pipe[0:PIPE_DEPTH-1];

    always_ff @(posedge clk) begin
        if (mac_en) begin
            r_pipe[0] <= row;
            c_pipe[0] <= col;
            k_pipe[0] <= kernel_mode;
            for (int i = 1; i < PIPE_DEPTH; i++) begin
                r_pipe[i] <= r_pipe[i-1];
                c_pipe[i] <= c_pipe[i-1];
                k_pipe[i] <= k_pipe[i-1];
            end
        end
    end

    // ============================================================
    // 기대값 계산 함수
    // PAD_DELAY로 지연된 좌표 기준 tap 수 계산
    // ============================================================
    function automatic int calc_taps(input logic [1:0] mode, input int r, c, w);
        automatic int cnt = 0;
        if (mode == 2'b01) return 1;
        for (int dr = -1; dr <= 1; dr++)
        for (int dc = -1; dc <= 1; dc++)
        if ((r + dr) >= 0 && (r + dr) < w && (c + dc) >= 0 && (c + dc) < w)
            cnt++;
        return cnt;
    endfunction

    // ============================================================
    // 모니터 + Scoreboard 검증
    // ============================================================
    always_ff @(negedge clk) begin
        if (mac_valid) begin
            automatic sb_entry_t entry;
            automatic int got;
            automatic int exp;
            automatic string res;

            if (sb_queue.size() == 0) begin
                $display(
                    "❌ SCOREBOARD UNDERFLOW — mac_valid인데 큐가 비어있음");
                fail_cnt++;
            end else begin
                entry = sb_queue.pop_front();

                $display("\n[%s | %s] R:%0d C:%0d", entry.label,
                         (entry.kmode == 2'b00) ? "3x3" : "1x1", entry.row,
                         entry.col);

                for (int ch = 0; ch < OUT_CH; ch++) begin
                    got = int'($signed(mac_out[ch*ACCUM_WIDTH+:ACCUM_WIDTH]));
                    exp = entry.exp[ch];
                    res = (got == exp) ? "✅ PASS" : "❌ FAIL";

                    $display("  CH%0d: got=%6d  exp=%6d  %s", ch, got, exp,
                             res);

                    if (got == exp) pass_cnt++;
                    else fail_cnt++;
                end
            end
        end
    end

    // ============================================================
    // 헬퍼 함수
    // ============================================================
    function automatic [DATA_WIDTH*IN_CH*9-1:0] pack_window_uniform(
        input logic [7:0] val);
        logic [DATA_WIDTH*IN_CH*9-1:0] res;
        for (int i = 0; i < 9 * IN_CH; i++) res[i*DATA_WIDTH+:DATA_WIDTH] = val;
        return res;
    endfunction

    // 채널별 다른 값 패킹 (IN_CH개 값 배열)
    function automatic [DATA_WIDTH*IN_CH*9-1:0] pack_window_per_ch(
        input logic [7:0] val[0:IN_CH-1]);
        logic [DATA_WIDTH*IN_CH*9-1:0] res;
        for (int i = 0; i < 9; i++)
        for (int ic = 0; ic < IN_CH; ic++)
        res[(i*IN_CH+ic)*DATA_WIDTH+:DATA_WIDTH] = val[ic];
        return res;
    endfunction

    function automatic [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] pack_kernel_uniform(
        input logic [7:0] val);
        logic [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] res;
        for (int i = 0; i < OUT_CH * IN_CH * 9; i++)
        res[i*DATA_WIDTH+:DATA_WIDTH] = val;
        return res;
    endfunction

    // 출력 채널별 다른 커널값 패킹
    function automatic [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] pack_kernel_per_och(
        input logic [7:0] val[0:OUT_CH-1]);
        logic [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] res;
        for (int oc = 0; oc < OUT_CH; oc++)
        for (int ic = 0; ic < IN_CH * 9; ic++)
        res[(oc*IN_CH*9+ic)*DATA_WIDTH+:DATA_WIDTH] = val[oc];
        return res;
    endfunction

    // ============================================================
    // Scoreboard Push + 실제 신호 인가 Task
    // ============================================================
    task automatic run_pixel(
        input string label, input logic [1:0] mode, input int r, c, w,
        input logic [DATA_WIDTH*IN_CH*9-1:0] win,
        input logic [DATA_WIDTH*IN_CH*9*OUT_CH-1:0] ker, input int in_passes,
        input logic [7:0] win_scalar,  // 균일값 기준 기대값 계산용
        input logic [7:0] ker_scalar    // (채널별 다른 값이면 직접 exp 계산 필요)
    );
        automatic sb_entry_t entry;
        automatic int taps = calc_taps(mode, r, c, w);
        automatic
        int
        base = int'(win_scalar) * int'(ker_scalar) * IN_CH * taps * in_passes;

        entry.row   = r;
        entry.col   = c;
        entry.kmode = mode;
        entry.label = label;
        for (int ch = 0; ch < OUT_CH; ch++)
            entry.exp[ch] = base;  // 균일 커널이면 모든 채널 동일

        // in_pass 루프
        for (int ip = 0; ip < in_passes; ip++) begin
            @(posedge clk);
            window_valid  <= 1'b1;
            accum_clr     <= (ip == 0);
            in_pass_done  <= (ip == in_passes - 1);
            row           <= 8'(r);
            col           <= 8'(c);
            current_width <= 9'(w);
            window_data   <= win;
            kernel_w      <= ker;
        end

        // 마지막 in_pass 후 valid 내리기
        @(posedge clk);
        window_valid <= 1'b0;
        accum_clr    <= 1'b0;
        in_pass_done <= 1'b0;

        // 큐에 push (mac_valid 뜨기 전에 먼저 넣어둠)
        sb_queue.push_back(entry);

        // 파이프라인 drain 대기
        repeat (PIPE_DEPTH + 1) @(posedge clk);

    endtask

    // ============================================================
    // 시나리오별 레이어 전체 스캔 Task
    // ============================================================
    task automatic run_layer_scan(
        input string label, input logic [1:0] mode, input logic [7:0] win_val,
        input logic [7:0] ker_val, input int sim_w, sim_h, input int in_passes);
        $display("\n============================================");
        $display("▶ LAYER SCAN: %s | %s | win=%0d ker=%0d ip=%0d %0dx%0d",
                 label, (mode == 2'b00) ? "3x3" : "1x1", win_val, ker_val,
                 in_passes, sim_w, sim_h);
        $display("============================================");

        kernel_mode = mode;

        for (int r = 0; r < sim_h; r++) begin
            for (int c = 0; c < sim_w; c++) begin
                run_pixel(label, mode, r, c, sim_w, pack_window_uniform(win_val
                          ), pack_kernel_uniform(ker_val), in_passes, win_val,
                          ker_val);
            end
            repeat (4) @(posedge clk);  // HBlank
        end
    endtask

    // ============================================================
    // 메인 시퀀스
    // ============================================================
    initial begin
        reset = 1;
        mac_en = 0;
        accum_clr = 0;
        in_pass_done = 0;
        window_valid = 0;
        kernel_mode = 0;
        row = 0;
        col = 0;
        current_width = 8;
        window_data = 0;
        kernel_w = 0;
        #20;
        reset  = 0;
        mac_en = 1;
        #10;

        // --------------------------------------------------------
        // 시나리오 1 — 기본 동작: win=1, ker=1, 3x3, in_pass=1
        // 기대: 내부픽셀=36, 엣지/코너는 패딩에 따라 감소
        // --------------------------------------------------------
        run_layer_scan("S1_Basic_3x3", 2'b00, 8'd1, 8'd1, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 2 — 1x1 커널: tap=1 고정, 패딩 무관
        // 기대: 모든 픽셀 = win * ker * IN_CH * 1 * in_pass
        // --------------------------------------------------------
        run_layer_scan("S2_Basic_1x1", 2'b01, 8'd1, 8'd1, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 3 — in_pass 누산 검증 (3pass)
        // 기대: 내부픽셀 = 1*1*4*9*3 = 108
        // --------------------------------------------------------
        run_layer_scan("S3_Accum_3pass", 2'b00, 8'd1, 8'd1, 8, 8, 3);

        // --------------------------------------------------------
        // 시나리오 4 — 큰 값 곱셈 (오버플로우 체크)
        // win=127, ker=127: 127*127*4*9*1 = 580,644
        // ACCUM_WIDTH=25 → 최대 33,554,431 → OK
        // --------------------------------------------------------
        run_layer_scan("S4_LargeVal", 2'b00, 8'd127, 8'd127, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 5 — 음수 커널 (signed 검증)
        // ker=-1 (8'hFF signed), win=1
        // 기대: 내부픽셀 = 1*(-1)*4*9*1 = -36
        // --------------------------------------------------------
        run_layer_scan("S5_NegKernel", 2'b00, 8'd1, 8'hFF, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 6 — in_pass 많음 (L4A 수준, 24pass, 1x1)
        // 기대: 모든 픽셀 = 1*1*4*1*24 = 96
        // --------------------------------------------------------
        run_layer_scan("S6_L4A_24pass_1x1", 2'b01, 8'd1, 8'd1, 8, 8, 24);

        // --------------------------------------------------------
        // 시나리오 7 — 작은 해상도 (4x4), 패딩 비율 높음
        // 3x3에서 코너/엣지 픽셀이 대부분
        // --------------------------------------------------------
        run_layer_scan("S7_Small4x4_3x3", 2'b00, 8'd2, 8'd2, 4, 4, 1);

        // --------------------------------------------------------
        // 시나리오 8 — win=0 제로 입력 (출력도 0이어야 함)
        // --------------------------------------------------------
        run_layer_scan("S8_ZeroInput", 2'b00, 8'd0, 8'd1, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 9 — ker=0 제로 커널
        // --------------------------------------------------------
        run_layer_scan("S9_ZeroKernel", 2'b00, 8'd1, 8'd0, 8, 8, 1);

        // --------------------------------------------------------
        // 시나리오 10 — 1x1 해상도 극단 케이스 (1x1 이미지)
        // 3x3: tap=1 (center만 유효), 기대=1*1*4*1*1=4
        // --------------------------------------------------------
        run_layer_scan("S10_1x1_Image_3x3", 2'b00, 8'd1, 8'd1, 1, 1, 1);

        #100;
        $display(
            "\n╔══════════════════════════════╗");
        $display("║  TOTAL PASS : %5d          ║", pass_cnt);
        $display("║  TOTAL FAIL : %5d          ║", fail_cnt);
        $display(
            "╚══════════════════════════════╝");
        $finish;
    end

endmodule
