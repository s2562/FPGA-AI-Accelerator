module memory_controller (
    input logic       clk,
    input logic       layer_start,
    input logic [3:0] layer_id,

    // Control Unit 관점의 현재 카운터
    input logic [4:0] in_pass,
    input logic [3:0] out_pass,
    input logic [7:0] row,
    input logic [7:0] col,
    input logic       mac_en,
    input logic       pp_valid,

    // 파이프라인 지연을 맞춘 쓰기용 카운터 (중요!)
    input logic [3:0] out_pass_delayed,
    input logic [7:0] row_delayed,
    input logic [7:0] col_delayed,

    // 1. Feature Memory (Read/Write)
    output logic        feat_wr,
    output logic [15:0] feat_waddr,
    output logic        feat_rd,
    output logic [15:0] feat_raddr[0:3],

    // 2. Weight Memory (Read only)
    // 3x3 필터 4개 채널을 한 번에 읽기 위한 주소
    output logic [11:0] weight_raddr,

    // 3. Scaler & Bias Memory (Read only)
    output logic [7:0] sb_raddr
);

    // ───────────────────────────────────────────────────────────
    // [1] Feature Memory: 쓰기 로직 (Pipeline Tail 저장용)
    // ───────────────────────────────────────────────────────────
    always_comb begin
        feat_wr = pp_valid;
        unique case (layer_id)
            4'd0:
            feat_waddr = {
                3'd0, out_pass_delayed[0], row_delayed[6:0], col_delayed[6:0]
            };  // L0: 128x128
            4'd1:
            feat_waddr = {
                3'd1, out_pass_delayed[1:0], row_delayed[5:0], col_delayed[5:0]
            };  // L1: 64x64
            4'd2:
            feat_waddr = {
                3'd2, out_pass_delayed[2:0], row_delayed[4:0], col_delayed[4:0]
            };  // L2: 32x32
            default:
            feat_waddr = {
                layer_id[2:0],
                out_pass_delayed[2:0],
                row_delayed[4:0],
                col_delayed[4:0]
            };
        endcase
    end
    // ───────────────────────────────────────────────────────────
    // [2] Feature Memory: 읽기 로직 (automatic 선언 추가)
    // ───────────────────────────────────────────────────────────
    always_comb begin
        feat_rd = mac_en & (layer_id != 0);

        for (int i = 0; i < 4; i++) begin : read_gen  // 블록 이름 추가
            // [해결] automatic 키워드를 추가하여 루프별 독립 변수임을 명시
            automatic logic [6:0] logical_ch;
            automatic logic [2:0] ch_group;

            logical_ch = {in_pass, i[1:0]};

            if (logical_ch < 6) ch_group = 3'd0;
            else if (logical_ch < 12) ch_group = 3'd1;
            else if (logical_ch < 18) ch_group = 3'd2;
            else if (logical_ch < 24) ch_group = 3'd3;
            else ch_group = 3'd4;

            unique case (layer_id)
                4'd1: feat_raddr[i] = {3'd0, ch_group[0], row[6:0], col[6:0]};
                4'd2: feat_raddr[i] = {3'd1, ch_group[1:0], row[5:0], col[5:0]};
                default:
                feat_raddr[i] = {
                    (layer_id[2:0] - 3'd1), ch_group[2:0], row[4:0], col[4:0]
                };
            endcase
        end
    end

    // ───────────────────────────────────────────────────────────
    // [3] Weight Memory: 3x3 필터 주소 생성
    // ───────────────────────────────────────────────────────────
    // 주소 구조: [Layer(3) | OutPass(3) | InPass(5) | kernel_idx(1)]
    // 3x3 필터 데이터가 메모리에 어떻게 쌓여있느냐에 따라 비트 구성은 조절 가능합니다.
    always_comb begin
        weight_raddr = {layer_id[2:0], out_pass[2:0], in_pass[4:0]};
    end

    // ───────────────────────────────────────────────────────────
    // [4] Scaler & Bias Memory: 출력 채널별 1:1 대응
    // ───────────────────────────────────────────────────────────
    // Scaler/Bias는 픽셀마다 바뀌는 게 아니라 '출력 채널'이 바뀔 때만 바뀝니다.
    // 주소 구조: [Layer(3) | OutPass(4)]
    always_comb begin
        sb_raddr = {layer_id[2:0], out_pass[3:0]};
    end

endmodule
