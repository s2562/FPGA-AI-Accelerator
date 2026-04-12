// dual_port_ram.sv — 듀얼포트 BRAM 베이스 모듈
// 설계 결정: 모듈명 dual_port_ram, 포트명 wr/rd (설계자 코딩 스타일 우선)
// DATA_WIDTH=8, DEPTH=2^n 으로 설계 → BRAM36K 낭비 최소화

module dual_port_ram #(
    parameter DEPTH      = 1024,
    parameter DATA_WIDTH = 8
)(
    input  logic                       clk,
    // Write port
    input  logic                       wr,
    input  logic [$clog2(DEPTH)-1:0]   waddr,
    input  logic [DATA_WIDTH-1:0]      wdata,
    // Read port
    input  logic                       rd,
    input  logic [$clog2(DEPTH)-1:0]   raddr,
    output logic [DATA_WIDTH-1:0]      rdata
);

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr)
            mem[waddr] <= wdata;
    end

    always_ff @(posedge clk) begin
        if (rd)
            rdata <= mem[raddr];
    end

endmodule
