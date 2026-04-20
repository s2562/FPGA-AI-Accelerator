// rtl/scaler.sv
// INT8 양자화 후 누산값을 다시 INT8 범위로 스케일링
// sum_final은 20비트, scale_factor는 8비트 고정소수점 (Q0.8)
// 출력: 상위 8비트 클램핑 → INT8

module scaler #(
    parameter IN_WIDTH    = 20,
    parameter SCALE_WIDTH = 8,
    parameter OUT_WIDTH   = 8,
    parameter OUT_CH      = 6
) (
    input  logic                               clk,
    input  logic                               reset,
    input  logic                               valid_in,
    input  logic signed [ IN_WIDTH*OUT_CH-1:0] data_in,
    input  logic signed [     SCALE_WIDTH-1:0] scale_factor,
    // output logics
    output logic signed [OUT_WIDTH*OUT_CH-1:0] data_out,
    output logic                               valid_out
);

  localparam MULT_WIDTH = IN_WIDTH + SCALE_WIDTH;  // 28비트

  logic signed [MULT_WIDTH-1:0] scaled [0:OUT_CH-1];
  logic signed [ OUT_WIDTH-1:0] clamped[0:OUT_CH-1];

  genvar c;
  generate
    for (c = 0; c < OUT_CH; c++) begin : gen_scale
      always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
          scaled[c] <= '0;
        end else if (valid_in) begin
          scaled[c] <= $signed(data_in[c*IN_WIDTH+:IN_WIDTH]) * $signed(scale_factor);
        end
      end

      // Q0.8 → 정수 변환: 우측 8비트 시프트 후 INT8 클램핑
      always_comb begin
        automatic logic signed [MULT_WIDTH-1:0] shifted;
        shifted = scaled[c] >>> 8;
        if (shifted > $signed(28'(127))) clamped[c] = 8'sd127;
        else if (shifted < $signed(28'(-128))) clamped[c] = -8'sd128;
        else clamped[c] = shifted[OUT_WIDTH-1:0];
      end

      assign data_out[c*OUT_WIDTH+:OUT_WIDTH] = clamped[c];
    end
  endgenerate

  // valid: 1클럭 지연 (곱셈 레지스터)
  always_ff @(posedge clk or posedge reset) begin
    if (reset) valid_out <= 1'b0;
    else valid_out <= valid_in;
  end

endmodule
