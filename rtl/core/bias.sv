// rtl/bias.sv
// 각 출력 채널에 bias 덧셈 (BN fusion된 bias)

module bias #(
    parameter DATA_WIDTH = 8,
    parameter OUT_CH     = 6
) (
    input  logic                                clk,
    input  logic                                reset,
    input  logic                                valid_in,
    input  logic signed [DATA_WIDTH*OUT_CH-1:0] data_in,
    input  logic signed [DATA_WIDTH*OUT_CH-1:0] bias,
    output logic signed [DATA_WIDTH*OUT_CH-1:0] data_out,
    output logic                                valid_out
);

    genvar c;
    generate
        for (c = 0; c < OUT_CH; c++) begin : gen_bias
            always_ff @(posedge clk or posedge reset) begin
                if (reset) begin
                    data_out[c*DATA_WIDTH+:DATA_WIDTH] <= '0;
                end else if (valid_in) begin
                    // 오버플로우 방지: 9비트로 덧셈 후 재클램핑
                    automatic logic signed [DATA_WIDTH:0] sum;
                    sum = $signed(data_in[c*DATA_WIDTH+:DATA_WIDTH]) +
                        $signed(bias[c*DATA_WIDTH+:DATA_WIDTH]);

                    if (sum > 9'sd127)
                        data_out[c*DATA_WIDTH+:DATA_WIDTH] <= 8'sd127;
                    else if (sum < -9'sd128)
                        data_out[c*DATA_WIDTH+:DATA_WIDTH] <= -8'sd128;
                    else
                        data_out[c*DATA_WIDTH +: DATA_WIDTH] <= sum[DATA_WIDTH-1:0];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge reset) begin
        if (reset) valid_out <= 1'b0;
        else valid_out <= valid_in;
    end

endmodule
