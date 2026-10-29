`timescale 1ns / 1ps
`default_nettype none
// ecg_detect_top.v : 50 Hz notch -> FIR 5-40 Hz -> CLT R-peak detector.
// r_index counts input samples (FIR delay 32 added back; the notch adds < 0.4 sample).
//
// v3 (2026-10-18 晚)：毛刺屏蔽整套删除（判据是绝对阈值，和信号幅度绑死，风险大于收益）。
// 保留：settle_sel（学习起点）与 cal_first（实时通路第一次判定只用于定标）。
module ecg_detect_top #(
    parameter integer FIR_TAPS   = 65,
    parameter integer FIR_DELAY  = 32,
    parameter integer CLT_W      = 21,
    parameter integer C_CONST    = 2,
    parameter integer LEARN      = 30,
    parameter integer SEARCH     = 22,
    parameter integer REFRACT    = 80,
    parameter integer REL_PERIOD = 250,
    parameter integer DATA_W     = 16,
    parameter integer ACC_W      = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     ce,           // 1 pulse per input sample
    input  wire signed [DATA_W-1:0] x,            // raw ECG sample (from ROM / ADC)
    input  wire [15:0]              settle_sel,   // 学习起点：ROM=0，实时=96
    input  wire                     cal_first,    // 1 = 实时通路第一次判定只用于定标
    output wire signed [DATA_W-1:0] y,            // band-passed sample
    output wire                     y_valid,
    output wire signed [ACC_W-1:0]  clt_out,      // CLT curve length (for the PS display)
    output wire                     clt_valid,
    output wire                     r_valid,      // one ce pulse per detected R peak
    output wire [31:0]              r_index,      // R peak position in INPUT samples
    output wire signed [DATA_W-1:0] r_amp         // R peak amplitude
);

    wire signed [DATA_W-1:0] notch_y;
    wire                     notch_valid;
    wire signed [DATA_W-1:0] fir_y;
    wire                     fir_valid;
    wire [31:0]              clt_index;

    notch_50hz #(
        .DATA_W(DATA_W)
    ) u_notch (
        .clk(clk), .rst_n(rst_n), .ce(ce), .x(x),
        .y(notch_y), .y_valid(notch_valid)
    );

    fir_bandpass #(
        .N(FIR_TAPS), .DATA_W(DATA_W), .COEF_W(16), .ACC_W(40)
    ) u_fir (
        .clk(clk), .rst_n(rst_n), .ce(notch_valid), .x(notch_y),
        .y(fir_y), .y_valid(fir_valid)
    );

    clt_qrs #(
        .W(CLT_W), .C_CONST(C_CONST), .LEARN(LEARN), .SEARCH(SEARCH), .REFRACT(REFRACT),
        .REL_PERIOD(REL_PERIOD), .DATA_W(DATA_W), .ACC_W(ACC_W)
    ) u_clt (
        .clk(clk), .rst_n(rst_n), .ce(fir_valid), .valid_in(fir_valid), .x(fir_y),
        .settle_sel(settle_sel), .cal_first(cal_first),
        .clt_out(clt_out), .clt_valid(clt_valid),
        .r_valid(r_valid), .r_index(clt_index), .r_amp(r_amp)
    );

    assign r_index = clt_index + FIR_DELAY;
    assign y       = fir_y;
    assign y_valid = fir_valid;

endmodule
`default_nettype wire
