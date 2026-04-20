`timescale 1ns / 1ps

module feature_mem #(
    parameter DEPTH      = 32768,
    parameter ADDR_WIDTH = 15
) (
    input logic clk,

    input logic                  wr,
    input logic [ADDR_WIDTH-1:0] waddr,
    input logic [          47:0] wdata,

    input  logic                  rd,
    input  logic [ADDR_WIDTH-1:0] raddr,
    input  logic [           1:0] bank_sel,
    output logic [          31:0] pixel_out
);

    // ── 6개 독립 1D 배열 → Vivado가 각각 BRAM으로 추론 ✅ ──
    logic [7:0] bank0[0:DEPTH-1];
    logic [7:0] bank1[0:DEPTH-1];
    logic [7:0] bank2[0:DEPTH-1];
    logic [7:0] bank3[0:DEPTH-1];
    logic [7:0] bank4[0:DEPTH-1];
    logic [7:0] bank5[0:DEPTH-1];

    // ── 쓰기: 6뱅크 동시 1클럭 ──
    always_ff @(posedge clk) begin
        if (wr) begin
            bank0[waddr] <= wdata[7:0];
            bank1[waddr] <= wdata[15:8];
            bank2[waddr] <= wdata[23:16];
            bank3[waddr] <= wdata[31:24];
            bank4[waddr] <= wdata[39:32];
            bank5[waddr] <= wdata[47:40];
        end
    end

    // ── 읽기: bank_sel에 따라 4뱅크 선택 동기 읽기 ──
    logic [7:0] r0, r1, r2, r3;

    always_ff @(posedge clk) begin
        if (rd) begin
            case (bank_sel)
                2'd0: begin  // ch 0,1,2,3
                    r0 <= bank0[raddr];
                    r1 <= bank1[raddr];
                    r2 <= bank2[raddr];
                    r3 <= bank3[raddr];
                end
                2'd1: begin  // ch 4,5,6,7
                    r0 <= bank4[raddr];
                    r1 <= bank5[raddr];
                    r2 <= bank0[raddr];
                    r3 <= bank1[raddr];
                end
                2'd2: begin  // ch 8,9,10,11
                    r0 <= bank2[raddr];
                    r1 <= bank3[raddr];
                    r2 <= bank4[raddr];
                    r3 <= bank5[raddr];
                end
                default: begin
                    r0 <= 8'd0;
                    r1 <= 8'd0;
                    r2 <= 8'd0;
                    r3 <= 8'd0;
                end
            endcase
        end
    end

    assign pixel_out = {r3, r2, r1, r0};

endmodule
