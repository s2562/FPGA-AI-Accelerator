// weight_mem.sv — 가중치 ROM 모듈
// dual_port_ram 인스턴스, $readmemh로 초기화, wr 항상 0 (ROM)
// DEPTH = 총 가중치 바이트 수, DATA_WIDTH = 8

module weight_mem #(
    parameter DEPTH      = 65536,   // 레이어별 크기에 맞게 조정 (2^n)
    parameter DATA_WIDTH = 8,
    parameter HEX_FILE   = "weights.hex"
)(
    input  logic                       clk,
    input  logic                       rd,
    input  logic [$clog2(DEPTH)-1:0]   raddr,
    output logic [DATA_WIDTH-1:0]      rdata
);

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        $readmemh(HEX_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (rd)
            rdata <= mem[raddr];
    end

endmodule
