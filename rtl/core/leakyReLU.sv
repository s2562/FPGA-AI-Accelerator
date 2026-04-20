// rtl/leaky_relu.sv
// LeakyReLU: x >= 0 → x,  x < 0 → x >>> 3 (≈ x * 0.125 ≈ α=0.1 근사)
// 정확한 0.1은 하드웨어에서 나눗셈 필요 → 1/8(0.125)로 근사, 오차 2.5%

module leaky_relu #(
    parameter DATA_WIDTH = 8,
    parameter OUT_CH     = 6
) (
    input  logic                                clk,
    input  logic                                reset,
    input  logic                                valid_in,
    input  logic                                leaky_relu_en,
    input  logic signed [DATA_WIDTH*OUT_CH-1:0] data_in,
    // output logics
    output logic signed [DATA_WIDTH*OUT_CH-1:0] data_out,
    output logic                                valid_out
);

  genvar c;
  generate
    for (c = 0; c < OUT_CH; c++) begin : gen_relu
      logic signed [DATA_WIDTH-1:0] din;
      assign din = $signed(data_in[c*DATA_WIDTH+:DATA_WIDTH]);

      always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
          data_out[c*DATA_WIDTH+:DATA_WIDTH] <= '0;
        end else if (valid_in) begin
          if (!leaky_relu_en) begin
            // HEAD 레이어: 활성화 없음 (그대로 통과)
            data_out[c*DATA_WIDTH+:DATA_WIDTH] <= din;
          end else if (din >= 8'sd0) begin
            data_out[c*DATA_WIDTH+:DATA_WIDTH] <= din;
          end else begin
            // α ≈ 1/8: 산술 우측 시프트 3
            data_out[c*DATA_WIDTH+:DATA_WIDTH] <= din >>> 3;
          end
        end
      end
    end
  endgenerate

  always_ff @(posedge clk or posedge reset) begin
    if (reset) valid_out <= 1'b0;
    else valid_out <= valid_in;
  end

endmodule
