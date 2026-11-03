`timescale 1ns / 1ps
`default_nettype none
// tb_notch_50hz.v -- self-checking testbench for notch_50hz
//
// 2026-10-19: 陷波器改为按 fs = 243.65 Hz、f0 = 50 Hz、Q = 8 设计。
//   所以本测试用"归一化频率"产生正弦，而不是固定 5 点/周期的表：
//     测试 1：f = 50 Hz（归一化 50/243.65 = 0.205212）-> 应被压到 < 100
//     测试 2：f = 10 Hz（归一化 0.041043）           -> 应基本无损（> 1800）
//     测试 3：阶跃响应 -> 应收敛、不发散
module tb_notch_50hz;

    localparam integer CP       = 64;                       // clocks per sample
    localparam real    FS       = 243.65;                   // 实测进样率
    localparam real    PI       = 3.14159265358979;

    reg clk = 1'b0;
    always #5 clk = ~clk;                                   // 100 MHz 仿真时钟

    reg                rst_n, ce;
    reg  signed [15:0] x;
    wire signed [15:0] y;
    wire               y_valid;

    notch_50hz dut (.clk(clk), .rst_n(rst_n), .ce(ce), .x(x), .y(y), .y_valid(y_valid));

    integer i, errs, checks;
    integer max50, max10, maxstep, last_y;
    real    ph;

    task send(input signed [15:0] v);
    begin
        @(negedge clk); x = v; ce = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); ce = 1'b0;
        repeat (CP-2) @(negedge clk);
    end
    endtask

    initial begin
        rst_n = 1'b0; ce = 1'b0; x = 16'sd0;
        errs = 0; checks = 0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        $display("========= notch_50hz : fs=243.65 Hz, f0=50 Hz, Q=8 =========");

        // ---- 1. 50 Hz（陷波中心）----
        max50 = 0;
        for (i = 0; i < 600; i = i + 1) begin
            ph = 2.0*PI*50.0*(i/FS);
            x  = $rtoi(2000.0*$sin(ph));
            send(x);
            if (i >= 400) begin
                if (y > max50)  max50 =  y;
                if (-y > max50) max50 = -y;
            end
        end
        checks = checks + 1;
        if (max50 < 100) $display("  ok   50 Hz in 2000 -> out peak %0d  (< 100)", max50);
        else begin
            errs = errs + 1;
            $display("  FAIL 50 Hz in 2000 -> out peak %0d  (expect < 100)", max50);
        end

        // ---- 2. 10 Hz（心电带内，应通过）----
        max10 = 0;
        for (i = 0; i < 600; i = i + 1) begin
            ph = 2.0*PI*10.0*(i/FS);
            x  = $rtoi(2000.0*$sin(ph));
            send(x);
            if (i >= 400) begin
                if (y > max10)  max10 =  y;
                if (-y > max10) max10 = -y;
            end
        end
        checks = checks + 1;
        if (max10 > 1800) $display("  ok   10 Hz in 2000 -> out peak %0d  (> 1800)", max10);
        else begin
            errs = errs + 1;
            $display("  FAIL 10 Hz in 2000 -> out peak %0d  (expect > 1800)", max10);
        end

        // ---- 3. 阶跃：陷波器应该让直流通过（收敛到 2000），不发散 ----
        for (i = 0; i < 300; i = i + 1) send(16'sd2000);
        maxstep = 0;
        for (i = 0; i < 600; i = i + 1) begin
            send(16'sd2000);
            if (y > maxstep)  maxstep =  y;
            if (-y > maxstep) maxstep = -y;
        end
        last_y = y;
        checks = checks + 1;
        if (maxstep < 2050) $display("  ok   step settles to DC (out peak %0d, expect ~2000)", maxstep);
        else begin
            errs = errs + 1;
            $display("  FAIL step peak %0d  (expect ~2000, notch must pass DC)", maxstep);
        end

        $display("-------------------------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errs);
        if (errs == 0) $display("  RESULT: PASS");
        else           $display("  RESULT: FAIL");
        $finish;
    end

endmodule
`default_nettype wire

