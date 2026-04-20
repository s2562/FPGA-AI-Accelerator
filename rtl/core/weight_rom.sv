`timescale 1ns / 1ps

// weight_rom.sv
// 가중치 ROM: $readmemh로 .hex 파일 초기화 → Vivado BRAM 추론

module weight_rom #(
    parameter DEPTH      = 65536,
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 16,
    parameter HEX_FILE   = "weights.mem"  // model/ 디렉토리의 .mem 파일
) (
    input  logic                  clk,
    input  logic                  rd,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata
);

    logic [DATA_WIDTH-1:0] mem[0:DEPTH-1];

    // ── 합성/시뮬레이션 모두 동작 ──
    initial begin
        $readmemh(HEX_FILE, mem);
    end

    // ── 동기 읽기 → BRAM 추론 ✅ ──
    always_ff @(posedge clk) begin
        if (rd) rdata <= mem[raddr];
    end

endmodule
