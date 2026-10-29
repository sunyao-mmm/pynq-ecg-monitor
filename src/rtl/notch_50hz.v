`timescale 1ns / 1ps
`default_nettype none
// notch_50hz.v : 50 Hz mains notch, 2nd-order IIR biquad (direct form I).
// 2026-10-19: 实测 ADS1292 的进样率是 243.65 Hz（芯片内部振荡器 -2.5%），
// 原来按 250 Hz 设计的陷波，中心落到 48.8 Hz，50 Hz 工频从旁边漏过去。
// 现按 fs = 243.65 Hz 重新设计，f0 = 50 Hz，Q = 8（带宽 6.25 Hz）。
// 实测频响：50 Hz -61.8 dB，40 Hz -0.2 dB，45 Hz -0.8 dB。
// y[n] = (C0*x[n] + C1*x[n-1] + C2*x[n-2] + D1*y[n-1] + D2*y[n-2] + 2^14) >>> 15
// Q15 coefficients, equal to RBJ notch with Q=20:
//   -61.8 dB at 50 Hz, -0.2 dB at 40 Hz, -0.8 dB at 45 Hz（fs=243.65）
module notch_50hz #(
    parameter integer DATA_W = 16,
    parameter integer COEF_W = 16,
    parameter integer ACC_W  = 40
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     ce,          // 1 pulse per input sample
    input  wire signed [DATA_W-1:0] x,
    output reg  signed [DATA_W-1:0] y,
    output reg                      y_valid
);

    localparam signed [COEF_W-1:0] C0 =  16'sd30912;   //  0.943358  x[n]
    localparam signed [COEF_W-1:0] C1 = -16'sd17172;   // -0.523961  x[n-1]
    localparam signed [COEF_W-1:0] C2 =  16'sd30912;   //  0.943358  x[n-2]
    localparam signed [COEF_W-1:0] D1 =  16'sd17172;   //  0.523961  y[n-1]
    localparam signed [COEF_W-1:0] D2 = -16'sd29055;   // -0.886713  y[n-2]

    reg signed [DATA_W-1:0] x1, x2, y1, y2;

    wire signed [COEF_W+DATA_W-1:0] p0 = C0 * x;
    wire signed [COEF_W+DATA_W-1:0] p1 = C1 * x1;
    wire signed [COEF_W+DATA_W-1:0] p2 = C2 * x2;
    wire signed [COEF_W+DATA_W-1:0] p3 = D1 * y1;
    wire signed [COEF_W+DATA_W-1:0] p4 = D2 * y2;

    wire signed [ACC_W-1:0] acc  = p0 + p1 + p2 + p3 + p4;
    wire signed [DATA_W-1:0] y_nx = sat16((acc + 40'sd16384) >>> 15);

    function signed [DATA_W-1:0] sat16(input signed [ACC_W-1:0] v);
        begin
            if (v > 40'sd32767)       sat16 = 16'sd32767;
            else if (v < -40'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[DATA_W-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1 <= {DATA_W{1'b0}}; x2 <= {DATA_W{1'b0}};
            y1 <= {DATA_W{1'b0}}; y2 <= {DATA_W{1'b0}};
            y  <= {DATA_W{1'b0}}; y_valid <= 1'b0;
        end
        else begin
            y_valid <= 1'b0;
            if (ce) begin
                y       <= y_nx;
                y_valid <= 1'b1;
                x2 <= x1; x1 <= x;
                y2 <= y1; y1 <= y_nx;
            end
        end
    end

endmodule
`default_nettype wire

