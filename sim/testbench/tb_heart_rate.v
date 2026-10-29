`timescale 1ns / 1ps
`default_nettype none
//==========================================================================
// tb_heart_rate.v -- unit test for heart_rate.v (v2, 4-beat median)
//
//   bpm 现在用"最近 4 拍的 RR 中位数"算，所以：
//     * 心率稳定时，几个搏动后就收敛到正确值
//     * 单个异常 RR 不会把 bpm 带跑（中位数把它挡掉）
//     * 超出 108..720 采样的 RR 直接判 rr_bad，bpm 不更新
//
//   本测试做四件事：
//     1) 打 6 拍 RR=250 -> bpm 应为 60
//     2) 打 6 拍 RR=167 -> bpm 应收敛到 90
//     3) 插一个 RR=200 的异常拍 -> bpm 应保持 90（中位数把它挡掉）
//     4) 插一个 RR=35（窗口外）  -> 应产生 rr_bad，bpm 仍不动
//==========================================================================
module tb_heart_rate;

    reg clk = 1'b0;
    always #5 clk = ~clk;                     // 100 MHz

    reg         rst_n;
    reg         r_valid;
    reg  [31:0] r_index;
    wire [15:0] bpm;
    wire        bpm_valid;
    wire [31:0] rr_samples, rr_avg;
    wire        rr_bad;
    wire [31:0] beat_count;

    heart_rate #(.FS_HZ(250), .BPM_MIN(30), .BPM_MAX(200)) dut (
        .clk(clk), .rst_n(rst_n), .r_valid(r_valid), .r_index(r_index),
        .bpm(bpm), .bpm_valid(bpm_valid),
        .rr_samples(rr_samples), .rr_avg(rr_avg), .rr_bad(rr_bad), .beat_count(beat_count)
    );

    integer errs, n_bad_pulse;
    integer k;
    reg [31:0] idx;

    task beat(input integer gap);
        begin
            idx = idx + gap;
            @(negedge clk); r_index = idx; r_valid = 1'b1;
            @(negedge clk); r_valid = 1'b0;
            repeat (40) @(negedge clk);       // 等串行除法器算完
        end
    endtask

    always @(posedge clk) if (rst_n && rr_bad) n_bad_pulse = n_bad_pulse + 1;

    initial begin
        rst_n = 1'b0; r_valid = 1'b0; r_index = 32'd0;
        errs = 0; n_bad_pulse = 0; idx = 32'd1000;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("=========== heart_rate unit test (4-beat median) ===========");

        beat(0);                              // 第一拍只用来打底
        for (k = 0; k < 6; k = k + 1) beat(250);
        $display("  6 拍 RR=250 之后: bpm=%0d (expect 60), rr_avg=%0d", bpm, rr_avg);
        if (bpm !== 16'd60) errs = errs + 1;

        for (k = 0; k < 6; k = k + 1) beat(167);
        $display("  6 拍 RR=167 之后: bpm=%0d (expect 90), rr_avg=%0d", bpm, rr_avg);
        if (bpm !== 16'd90) errs = errs + 1;

        beat(200);                            // 单个异常拍（仍在窗口内）
        $display("  插一个 RR=200  : bpm=%0d (expect 90，中位数挡掉)", bpm);
        if (bpm !== 16'd90) errs = errs + 1;

        beat(35);                             // 窗口外
        repeat (10) @(negedge clk);
        $display("  插一个 RR=35   : bpm=%0d (expect 90，不更新), rr_bad 脉冲=%0d (expect 1)",
                 bpm, n_bad_pulse);
        if (bpm !== 16'd90)   errs = errs + 1;
        if (n_bad_pulse !== 1) errs = errs + 1;

        $display("-------------------------------------------------");
        if (errs == 0) $display("  RESULT: PASS");
        else           $display("  RESULT: FAIL  (errors=%0d)", errs);
        $display("=================================================");
        $finish;
    end

endmodule
`default_nettype wire
