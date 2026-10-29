`timescale 1ns / 1ps
`default_nettype none
//==========================================================================
// tb_ecg_core.v -- round 1 of phase 2-2: the real ecg_core (ROM player + FIR
//                 + CLT + heart rate) driven with the 1024 MIT-BIH samples.
//
//   A behavioural ROM with 1 clock read latency stands in for the Block Memory
//   Generator that will sit in the block design.
//
//   expected: R peaks at input indices 77 / 370 / 663 / 947
//             bpm = 74 / 74 / 76 ,  beat_count = 4
//
//   CLK_PER_SAMPLE is set to 64 here (the board uses 277778) so the run is short.
//   ASCII only on purpose.
//==========================================================================
module tb_ecg_core;

    localparam integer NSAMP = 711;
    localparam integer CLKS  = 64;          // clocks per sample in this simulation

    reg clk = 1'b0;
    always #5 clk = ~clk;                   // 100 MHz

    reg  rst_n, run, soft_rst;
    reg  [31:0] cap_len_in;
    reg         src_sel;
    reg  signed [15:0] adc_sample;
    reg         adc_valid;
    wire [9:0]  rom_addr;
    reg  signed [15:0] rom_data;
    wire        cap_we;
    wire [11:0] cap_addr;
    wire [31:0] cap_data;
    wire [31:0] st_clt_now, st_r_index, st_rr_samples, st_beat_count, st_rr_bad_cnt;
    wire [15:0] st_r_amp, st_bpm;
    wire        st_cap_done;

    reg signed [15:0] mem [0:NSAMP-1];      // the behavioural ROM contents

    integer i, n_det, n_bpm, errs, checks;
    reg [31:0] det [0:31];
    reg [15:0] bpm_seen [0:7];
    integer exp_det [0:3];
    integer exp_bpm [0:3];

    // ---- behavioural ROM with 2 clock read latency (this is what the BMG
    //      summary reports, so we verify the worst case here) ----
    reg signed [15:0] rom_q1;
    always @(posedge clk) begin
        rom_q1   <= mem[rom_addr];
        rom_data <= rom_q1;
    end

    ecg_core #(.CLK_PER_SAMPLE(CLKS), .ROM_AW(10), .CAP_AW(12), .ROM_LEN(711), .SETTLE(0), .CAL_FIRST(0)) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .soft_rst(soft_rst), .cap_len_in(cap_len_in),
        .src_sel(src_sel), .adc_sample(adc_sample), .adc_valid(adc_valid),
        .rom_addr(rom_addr), .rom_data(rom_data),
        .cap_we(cap_we), .cap_addr(cap_addr), .cap_data(cap_data),
        .st_clt_now(st_clt_now), .st_r_index(st_r_index), .st_r_amp(st_r_amp), .st_bpm(st_bpm),
        .st_rr_samples(st_rr_samples), .st_beat_count(st_beat_count),
        .st_rr_bad_cnt(st_rr_bad_cnt), .st_cap_done(st_cap_done)
    );

    // ---- the testbench acts like the ARM: it samples the status ports ----
    reg        clt_valid_d;
    reg        r_valid_d;      // r_valid one clock earlier (the cycle that was captured)

    // ---- capture format monitor: TWO 32-bit words per sample ----------------
    //   even word address : { 15'b0, r_valid, y[15:0] }   band-passed ECG + R flag
    //   odd  word address : clt_out                       CLT value
    integer cap_we_cnt, cap_w0_cnt, cap_w1_cnt, cap_clt_cnt, cap_fmt_errs;
    always @(posedge clk) begin
        clt_valid_d <= cap_we;                      // one capture write pulse
        r_valid_d   <= dut.u_det.r_valid;           // the flag that is being captured
        if (rst_n && dut.u_det.clt_valid) cap_clt_cnt = cap_clt_cnt + 1;
        if (rst_n && cap_we) begin
            cap_we_cnt = cap_we_cnt + 1;
            // NOTE: cap_we / cap_addr / cap_data are all registered on the same
            // edge, so the address seen here is already the NEXT one.  The word
            // that was just written therefore sits at (cap_addr - 1), i.e. the
            // waveform word shows up here when cap_addr is ODD.
            if (cap_addr[0] == 1'b1) begin          // waveform word (addr-1 even)
                cap_w0_cnt = cap_w0_cnt + 1;
                if (cap_data[15:0] !== dut.u_det.y) begin
                    cap_fmt_errs = cap_fmt_errs + 1;
                    if (cap_fmt_errs < 4)
                        $display("  FAIL capture wave word: got %0d  y = %0d",
                                 cap_data[15:0], dut.u_det.y);
                end
                if (cap_data[16] !== r_valid_d) begin
                    cap_fmt_errs = cap_fmt_errs + 1;
                    if (cap_fmt_errs < 4)
                        $display("  FAIL capture R flag: got %0d  r_valid = %0d",
                                 cap_data[16], r_valid_d);
                end
            end
            else begin                              // CLT word (addr-1 odd)
                cap_w1_cnt = cap_w1_cnt + 1;
                // 2026-10-18: CLT 字的最高字节现在放 LOFF_STAT（bit31 恒为 1），
                // 比较时只看低 24 位。
                if ((cap_data & 32'h00FF_FFFF) !== (dut.u_det.clt_out & 32'h00FF_FFFF)) begin
                    cap_fmt_errs = cap_fmt_errs + 1;
                    if (cap_fmt_errs < 4)
                        $display("  FAIL capture CLT word: got %0d  clt = %0d",
                                 cap_data, dut.u_det.clt_out);
                end
            end
        end
    end

    // monitor: catch the R peaks and the bpm updates the same way the PS would
    reg r_valid_prev;
    always @(posedge clk) r_valid_prev <= dut.u_det.r_valid;
    always @(posedge clk) begin
        if (rst_n && !r_valid_prev && dut.u_det.r_valid && n_det < 32) begin
            det[n_det] = dut.u_det.r_index;
            $display("  [%0t] R peak: index=%0d  amp=%0d", $time, dut.u_det.r_index, dut.u_det.r_amp);
            n_det = n_det + 1;
        end
        if (rst_n && dut.u_hr.bpm_valid && n_bpm < 8) begin
            bpm_seen[n_bpm] = dut.u_hr.bpm;
            $display("  [%0t] bpm = %0d   (rr = %0d samples)", $time, dut.u_hr.bpm, dut.u_hr.rr_samples);
            n_bpm = n_bpm + 1;
        end
    end

    task clear_stats;
        begin
            n_det = 0; n_bpm = 0;
            cap_we_cnt = 0; cap_w0_cnt = 0; cap_w1_cnt = 0;
            cap_clt_cnt = 0; cap_fmt_errs = 0;
            for (i = 0; i < 32; i = i + 1) det[i] = 32'd0;
            for (i = 0; i < 8;  i = i + 1) bpm_seen[i] = 16'd0;
        end
    endtask

    task check_all;
        integer k;
        begin
            $display("detected %0d R peaks (expect 4)", n_det);
            for (k = 0; k < 4; k = k + 1) begin
                checks = checks + 1;
                if (k < n_det && ($signed(det[k]) - $signed(exp_det[k])) <= 2 && ($signed(exp_det[k]) - $signed(det[k])) <= 2) $display("  ok   R peak[%0d] = %0d", k, det[k]);
                else begin
                    errs = errs + 1;
                    $display("  FAIL R peak[%0d] = %0d   (expect %0d)", k, det[k], exp_det[k]);
                end
            end
            $display("bpm updates: %0d (expect 3)", n_bpm);
            for (k = 0; k < 3; k = k + 1) begin
                checks = checks + 1;
                if (k < n_bpm && bpm_seen[k] === exp_bpm[k]) $display("  ok   bpm[%0d] = %0d", k, bpm_seen[k]);
                else begin
                    errs = errs + 1;
                    $display("  FAIL bpm[%0d] = %0d   (expect %0d)", k, bpm_seen[k], exp_bpm[k]);
                end
            end
            checks = checks + 1;
            if (st_beat_count === 32'd4) $display("  ok   st_beat_count = 4");
            else begin errs = errs + 1; $display("  FAIL st_beat_count = %0d (expect 4)", st_beat_count); end

            checks = checks + 1;
            if (($signed(st_rr_samples) - $signed(exp_det[3]-exp_det[2])) <= 2 && ($signed(exp_det[3]-exp_det[2]) - $signed(st_rr_samples)) <= 2) $display("  ok   st_rr_samples = %0d (last RR)", st_rr_samples);
            else begin errs = errs + 1; $display("  FAIL st_rr_samples = %0d (expect %0d)", st_rr_samples, exp_det[3]-exp_det[2]); end

            checks = checks + 1;
            if (st_cap_done === 1'b0) $display("  ok   st_cap_done = 0 (capture still running, buffer 4096 > 711)");
            else begin errs = errs + 1; $display("  FAIL st_cap_done = %0d", st_cap_done); end

            // ---- capture buffer format: 2 words per sample ----
            checks = checks + 1;
            if (cap_fmt_errs == 0 && cap_w0_cnt == cap_w1_cnt &&
                cap_we_cnt == 2*cap_clt_cnt && cap_w0_cnt > 0)
                $display("  ok   capture = %0d wave + %0d CLT words for %0d samples",
                         cap_w0_cnt, cap_w1_cnt, cap_clt_cnt);
            else begin
                errs = errs + 1;
                $display("  FAIL capture: we=%0d w0=%0d w1=%0d clt=%0d fmterr=%0d",
                         cap_we_cnt, cap_w0_cnt, cap_w1_cnt, cap_clt_cnt, cap_fmt_errs);
            end
        end
    endtask

    initial begin
        exp_det[0] = 54;  exp_det[1] = 258; exp_det[2] = 461; exp_det[3] = 658;
    // 2026-10-18: bpm 改为"最近 4 拍 RR 的中位数"，最后一拍 203->197 的小变化
    // 会被中位数平滑掉，读数是 74 而不是 76。这是预期的滤波行为。
    exp_bpm[0] = 74;  exp_bpm[1] = 74;  exp_bpm[2] = 74;  exp_bpm[3] = -1;

        mem[0] = -32'sd145;
        mem[1] = -32'sd145;
        mem[2] = -32'sd145;
        mem[3] = -32'sd145;
        mem[4] = -32'sd145;
        mem[5] = -32'sd145;
        mem[6] = -32'sd120;
        mem[7] = -32'sd145;
        mem[8] = -32'sd150;
        mem[9] = -32'sd160;
        mem[10] = -32'sd160;
        mem[11] = -32'sd175;
        mem[12] = -32'sd185;
        mem[13] = -32'sd170;
        mem[14] = -32'sd175;
        mem[15] = -32'sd180;
        mem[16] = -32'sd180;
        mem[17] = -32'sd155;
        mem[18] = -32'sd135;
        mem[19] = -32'sd190;
        mem[20] = -32'sd205;
        mem[21] = -32'sd225;
        mem[22] = -32'sd245;
        mem[23] = -32'sd260;
        mem[24] = -32'sd275;
        mem[25] = -32'sd275;
        mem[26] = -32'sd265;
        mem[27] = -32'sd255;
        mem[28] = -32'sd275;
        mem[29] = -32'sd290;
        mem[30] = -32'sd290;
        mem[31] = -32'sd290;
        mem[32] = -32'sd295;
        mem[33] = -32'sd305;
        mem[34] = -32'sd285;
        mem[35] = -32'sd275;
        mem[36] = -32'sd280;
        mem[37] = -32'sd305;
        mem[38] = -32'sd290;
        mem[39] = -32'sd280;
        mem[40] = -32'sd290;
        mem[41] = -32'sd315;
        mem[42] = -32'sd320;
        mem[43] = -32'sd335;
        mem[44] = -32'sd385;
        mem[45] = -32'sd385;
        mem[46] = -32'sd455;
        mem[47] = -32'sd485;
        mem[48] = -32'sd425;
        mem[49] = -32'sd330;
        mem[50] = -32'sd70;
        mem[51] = 32'sd120;
        mem[52] = 32'sd375;
        mem[53] = 32'sd780;
        mem[54] = 32'sd840;
        mem[55] = 32'sd520;
        mem[56] = 32'sd170;
        mem[57] = -32'sd365;
        mem[58] = -32'sd435;
        mem[59] = -32'sd425;
        mem[60] = -32'sd330;
        mem[61] = -32'sd325;
        mem[62] = -32'sd345;
        mem[63] = -32'sd330;
        mem[64] = -32'sd315;
        mem[65] = -32'sd310;
        mem[66] = -32'sd335;
        mem[67] = -32'sd340;
        mem[68] = -32'sd325;
        mem[69] = -32'sd335;
        mem[70] = -32'sd330;
        mem[71] = -32'sd330;
        mem[72] = -32'sd325;
        mem[73] = -32'sd330;
        mem[74] = -32'sd345;
        mem[75] = -32'sd335;
        mem[76] = -32'sd325;
        mem[77] = -32'sd305;
        mem[78] = -32'sd320;
        mem[79] = -32'sd330;
        mem[80] = -32'sd335;
        mem[81] = -32'sd340;
        mem[82] = -32'sd355;
        mem[83] = -32'sd355;
        mem[84] = -32'sd340;
        mem[85] = -32'sd330;
        mem[86] = -32'sd330;
        mem[87] = -32'sd350;
        mem[88] = -32'sd325;
        mem[89] = -32'sd330;
        mem[90] = -32'sd330;
        mem[91] = -32'sd335;
        mem[92] = -32'sd340;
        mem[93] = -32'sd330;
        mem[94] = -32'sd350;
        mem[95] = -32'sd355;
        mem[96] = -32'sd345;
        mem[97] = -32'sd330;
        mem[98] = -32'sd335;
        mem[99] = -32'sd330;
        mem[100] = -32'sd330;
        mem[101] = -32'sd335;
        mem[102] = -32'sd335;
        mem[103] = -32'sd345;
        mem[104] = -32'sd355;
        mem[105] = -32'sd340;
        mem[106] = -32'sd335;
        mem[107] = -32'sd350;
        mem[108] = -32'sd350;
        mem[109] = -32'sd345;
        mem[110] = -32'sd335;
        mem[111] = -32'sd335;
        mem[112] = -32'sd355;
        mem[113] = -32'sd355;
        mem[114] = -32'sd345;
        mem[115] = -32'sd335;
        mem[116] = -32'sd360;
        mem[117] = -32'sd360;
        mem[118] = -32'sd360;
        mem[119] = -32'sd360;
        mem[120] = -32'sd370;
        mem[121] = -32'sd370;
        mem[122] = -32'sd360;
        mem[123] = -32'sd360;
        mem[124] = -32'sd375;
        mem[125] = -32'sd365;
        mem[126] = -32'sd365;
        mem[127] = -32'sd360;
        mem[128] = -32'sd365;
        mem[129] = -32'sd370;
        mem[130] = -32'sd330;
        mem[131] = -32'sd325;
        mem[132] = -32'sd335;
        mem[133] = -32'sd340;
        mem[134] = -32'sd315;
        mem[135] = -32'sd300;
        mem[136] = -32'sd290;
        mem[137] = -32'sd290;
        mem[138] = -32'sd285;
        mem[139] = -32'sd255;
        mem[140] = -32'sd250;
        mem[141] = -32'sd265;
        mem[142] = -32'sd255;
        mem[143] = -32'sd245;
        mem[144] = -32'sd245;
        mem[145] = -32'sd245;
        mem[146] = -32'sd255;
        mem[147] = -32'sd240;
        mem[148] = -32'sd255;
        mem[149] = -32'sd245;
        mem[150] = -32'sd250;
        mem[151] = -32'sd250;
        mem[152] = -32'sd265;
        mem[153] = -32'sd260;
        mem[154] = -32'sd265;
        mem[155] = -32'sd265;
        mem[156] = -32'sd260;
        mem[157] = -32'sd280;
        mem[158] = -32'sd290;
        mem[159] = -32'sd275;
        mem[160] = -32'sd260;
        mem[161] = -32'sd280;
        mem[162] = -32'sd285;
        mem[163] = -32'sd275;
        mem[164] = -32'sd265;
        mem[165] = -32'sd270;
        mem[166] = -32'sd290;
        mem[167] = -32'sd280;
        mem[168] = -32'sd275;
        mem[169] = -32'sd280;
        mem[170] = -32'sd300;
        mem[171] = -32'sd305;
        mem[172] = -32'sd295;
        mem[173] = -32'sd310;
        mem[174] = -32'sd310;
        mem[175] = -32'sd295;
        mem[176] = -32'sd285;
        mem[177] = -32'sd285;
        mem[178] = -32'sd295;
        mem[179] = -32'sd310;
        mem[180] = -32'sd295;
        mem[181] = -32'sd300;
        mem[182] = -32'sd310;
        mem[183] = -32'sd325;
        mem[184] = -32'sd310;
        mem[185] = -32'sd290;
        mem[186] = -32'sd310;
        mem[187] = -32'sd330;
        mem[188] = -32'sd315;
        mem[189] = -32'sd305;
        mem[190] = -32'sd310;
        mem[191] = -32'sd330;
        mem[192] = -32'sd325;
        mem[193] = -32'sd315;
        mem[194] = -32'sd305;
        mem[195] = -32'sd305;
        mem[196] = -32'sd300;
        mem[197] = -32'sd305;
        mem[198] = -32'sd300;
        mem[199] = -32'sd300;
        mem[200] = -32'sd305;
        mem[201] = -32'sd290;
        mem[202] = -32'sd280;
        mem[203] = -32'sd305;
        mem[204] = -32'sd315;
        mem[205] = -32'sd295;
        mem[206] = -32'sd290;
        mem[207] = -32'sd270;
        mem[208] = -32'sd275;
        mem[209] = -32'sd275;
        mem[210] = -32'sd250;
        mem[211] = -32'sd250;
        mem[212] = -32'sd225;
        mem[213] = -32'sd220;
        mem[214] = -32'sd200;
        mem[215] = -32'sd205;
        mem[216] = -32'sd230;
        mem[217] = -32'sd220;
        mem[218] = -32'sd225;
        mem[219] = -32'sd225;
        mem[220] = -32'sd230;
        mem[221] = -32'sd240;
        mem[222] = -32'sd235;
        mem[223] = -32'sd210;
        mem[224] = -32'sd205;
        mem[225] = -32'sd285;
        mem[226] = -32'sd285;
        mem[227] = -32'sd300;
        mem[228] = -32'sd330;
        mem[229] = -32'sd330;
        mem[230] = -32'sd315;
        mem[231] = -32'sd320;
        mem[232] = -32'sd325;
        mem[233] = -32'sd340;
        mem[234] = -32'sd345;
        mem[235] = -32'sd340;
        mem[236] = -32'sd350;
        mem[237] = -32'sd355;
        mem[238] = -32'sd330;
        mem[239] = -32'sd330;
        mem[240] = -32'sd320;
        mem[241] = -32'sd355;
        mem[242] = -32'sd340;
        mem[243] = -32'sd330;
        mem[244] = -32'sd330;
        mem[245] = -32'sd350;
        mem[246] = -32'sd360;
        mem[247] = -32'sd380;
        mem[248] = -32'sd445;
        mem[249] = -32'sd475;
        mem[250] = -32'sd535;
        mem[251] = -32'sd505;
        mem[252] = -32'sd415;
        mem[253] = -32'sd160;
        mem[254] = -32'sd15;
        mem[255] = 32'sd490;
        mem[256] = 32'sd720;
        mem[257] = 32'sd940;
        mem[258] = 32'sd905;
        mem[259] = 32'sd755;
        mem[260] = 32'sd165;
        mem[261] = -32'sd110;
        mem[262] = -32'sd390;
        mem[263] = -32'sd450;
        mem[264] = -32'sd455;
        mem[265] = -32'sd425;
        mem[266] = -32'sd390;
        mem[267] = -32'sd385;
        mem[268] = -32'sd390;
        mem[269] = -32'sd380;
        mem[270] = -32'sd380;
        mem[271] = -32'sd385;
        mem[272] = -32'sd385;
        mem[273] = -32'sd375;
        mem[274] = -32'sd395;
        mem[275] = -32'sd410;
        mem[276] = -32'sd400;
        mem[277] = -32'sd395;
        mem[278] = -32'sd405;
        mem[279] = -32'sd395;
        mem[280] = -32'sd375;
        mem[281] = -32'sd390;
        mem[282] = -32'sd405;
        mem[283] = -32'sd410;
        mem[284] = -32'sd410;
        mem[285] = -32'sd390;
        mem[286] = -32'sd395;
        mem[287] = -32'sd415;
        mem[288] = -32'sd400;
        mem[289] = -32'sd405;
        mem[290] = -32'sd410;
        mem[291] = -32'sd410;
        mem[292] = -32'sd400;
        mem[293] = -32'sd400;
        mem[294] = -32'sd390;
        mem[295] = -32'sd405;
        mem[296] = -32'sd390;
        mem[297] = -32'sd390;
        mem[298] = -32'sd385;
        mem[299] = -32'sd410;
        mem[300] = -32'sd395;
        mem[301] = -32'sd390;
        mem[302] = -32'sd375;
        mem[303] = -32'sd395;
        mem[304] = -32'sd410;
        mem[305] = -32'sd390;
        mem[306] = -32'sd390;
        mem[307] = -32'sd405;
        mem[308] = -32'sd415;
        mem[309] = -32'sd415;
        mem[310] = -32'sd395;
        mem[311] = -32'sd405;
        mem[312] = -32'sd420;
        mem[313] = -32'sd420;
        mem[314] = -32'sd415;
        mem[315] = -32'sd425;
        mem[316] = -32'sd435;
        mem[317] = -32'sd430;
        mem[318] = -32'sd430;
        mem[319] = -32'sd430;
        mem[320] = -32'sd450;
        mem[321] = -32'sd450;
        mem[322] = -32'sd435;
        mem[323] = -32'sd450;
        mem[324] = -32'sd455;
        mem[325] = -32'sd460;
        mem[326] = -32'sd455;
        mem[327] = -32'sd450;
        mem[328] = -32'sd470;
        mem[329] = -32'sd475;
        mem[330] = -32'sd450;
        mem[331] = -32'sd445;
        mem[332] = -32'sd435;
        mem[333] = -32'sd440;
        mem[334] = -32'sd410;
        mem[335] = -32'sd370;
        mem[336] = -32'sd365;
        mem[337] = -32'sd365;
        mem[338] = -32'sd340;
        mem[339] = -32'sd315;
        mem[340] = -32'sd320;
        mem[341] = -32'sd330;
        mem[342] = -32'sd320;
        mem[343] = -32'sd310;
        mem[344] = -32'sd300;
        mem[345] = -32'sd320;
        mem[346] = -32'sd315;
        mem[347] = -32'sd305;
        mem[348] = -32'sd295;
        mem[349] = -32'sd320;
        mem[350] = -32'sd305;
        mem[351] = -32'sd310;
        mem[352] = -32'sd300;
        mem[353] = -32'sd320;
        mem[354] = -32'sd325;
        mem[355] = -32'sd305;
        mem[356] = -32'sd315;
        mem[357] = -32'sd315;
        mem[358] = -32'sd315;
        mem[359] = -32'sd310;
        mem[360] = -32'sd290;
        mem[361] = -32'sd305;
        mem[362] = -32'sd320;
        mem[363] = -32'sd315;
        mem[364] = -32'sd315;
        mem[365] = -32'sd315;
        mem[366] = -32'sd330;
        mem[367] = -32'sd315;
        mem[368] = -32'sd320;
        mem[369] = -32'sd325;
        mem[370] = -32'sd335;
        mem[371] = -32'sd335;
        mem[372] = -32'sd335;
        mem[373] = -32'sd325;
        mem[374] = -32'sd345;
        mem[375] = -32'sd345;
        mem[376] = -32'sd335;
        mem[377] = -32'sd330;
        mem[378] = -32'sd345;
        mem[379] = -32'sd345;
        mem[380] = -32'sd320;
        mem[381] = -32'sd330;
        mem[382] = -32'sd340;
        mem[383] = -32'sd355;
        mem[384] = -32'sd335;
        mem[385] = -32'sd330;
        mem[386] = -32'sd335;
        mem[387] = -32'sd360;
        mem[388] = -32'sd355;
        mem[389] = -32'sd340;
        mem[390] = -32'sd345;
        mem[391] = -32'sd345;
        mem[392] = -32'sd345;
        mem[393] = -32'sd330;
        mem[394] = -32'sd335;
        mem[395] = -32'sd345;
        mem[396] = -32'sd350;
        mem[397] = -32'sd340;
        mem[398] = -32'sd345;
        mem[399] = -32'sd345;
        mem[400] = -32'sd350;
        mem[401] = -32'sd340;
        mem[402] = -32'sd330;
        mem[403] = -32'sd340;
        mem[404] = -32'sd340;
        mem[405] = -32'sd335;
        mem[406] = -32'sd330;
        mem[407] = -32'sd345;
        mem[408] = -32'sd345;
        mem[409] = -32'sd340;
        mem[410] = -32'sd315;
        mem[411] = -32'sd295;
        mem[412] = -32'sd295;
        mem[413] = -32'sd285;
        mem[414] = -32'sd265;
        mem[415] = -32'sd265;
        mem[416] = -32'sd255;
        mem[417] = -32'sd250;
        mem[418] = -32'sd240;
        mem[419] = -32'sd215;
        mem[420] = -32'sd240;
        mem[421] = -32'sd240;
        mem[422] = -32'sd245;
        mem[423] = -32'sd245;
        mem[424] = -32'sd250;
        mem[425] = -32'sd275;
        mem[426] = -32'sd265;
        mem[427] = -32'sd250;
        mem[428] = -32'sd220;
        mem[429] = -32'sd230;
        mem[430] = -32'sd270;
        mem[431] = -32'sd280;
        mem[432] = -32'sd305;
        mem[433] = -32'sd320;
        mem[434] = -32'sd340;
        mem[435] = -32'sd335;
        mem[436] = -32'sd335;
        mem[437] = -32'sd370;
        mem[438] = -32'sd360;
        mem[439] = -32'sd350;
        mem[440] = -32'sd355;
        mem[441] = -32'sd375;
        mem[442] = -32'sd380;
        mem[443] = -32'sd370;
        mem[444] = -32'sd365;
        mem[445] = -32'sd380;
        mem[446] = -32'sd380;
        mem[447] = -32'sd375;
        mem[448] = -32'sd370;
        mem[449] = -32'sd390;
        mem[450] = -32'sd410;
        mem[451] = -32'sd435;
        mem[452] = -32'sd465;
        mem[453] = -32'sd520;
        mem[454] = -32'sd555;
        mem[455] = -32'sd525;
        mem[456] = -32'sd405;
        mem[457] = -32'sd90;
        mem[458] = 32'sd120;
        mem[459] = 32'sd410;
        mem[460] = 32'sd885;
        mem[461] = 32'sd960;
        mem[462] = 32'sd520;
        mem[463] = 32'sd50;
        mem[464] = -32'sd500;
        mem[465] = -32'sd505;
        mem[466] = -32'sd415;
        mem[467] = -32'sd395;
        mem[468] = -32'sd390;
        mem[469] = -32'sd390;
        mem[470] = -32'sd395;
        mem[471] = -32'sd395;
        mem[472] = -32'sd405;
        mem[473] = -32'sd395;
        mem[474] = -32'sd395;
        mem[475] = -32'sd405;
        mem[476] = -32'sd400;
        mem[477] = -32'sd400;
        mem[478] = -32'sd405;
        mem[479] = -32'sd420;
        mem[480] = -32'sd405;
        mem[481] = -32'sd405;
        mem[482] = -32'sd420;
        mem[483] = -32'sd435;
        mem[484] = -32'sd420;
        mem[485] = -32'sd410;
        mem[486] = -32'sd405;
        mem[487] = -32'sd430;
        mem[488] = -32'sd420;
        mem[489] = -32'sd410;
        mem[490] = -32'sd410;
        mem[491] = -32'sd420;
        mem[492] = -32'sd400;
        mem[493] = -32'sd395;
        mem[494] = -32'sd400;
        mem[495] = -32'sd395;
        mem[496] = -32'sd405;
        mem[497] = -32'sd390;
        mem[498] = -32'sd400;
        mem[499] = -32'sd415;
        mem[500] = -32'sd425;
        mem[501] = -32'sd415;
        mem[502] = -32'sd415;
        mem[503] = -32'sd425;
        mem[504] = -32'sd425;
        mem[505] = -32'sd415;
        mem[506] = -32'sd400;
        mem[507] = -32'sd410;
        mem[508] = -32'sd425;
        mem[509] = -32'sd410;
        mem[510] = -32'sd395;
        mem[511] = -32'sd400;
        mem[512] = -32'sd405;
        mem[513] = -32'sd385;
        mem[514] = -32'sd390;
        mem[515] = -32'sd390;
        mem[516] = -32'sd415;
        mem[517] = -32'sd405;
        mem[518] = -32'sd405;
        mem[519] = -32'sd415;
        mem[520] = -32'sd420;
        mem[521] = -32'sd425;
        mem[522] = -32'sd415;
        mem[523] = -32'sd410;
        mem[524] = -32'sd435;
        mem[525] = -32'sd435;
        mem[526] = -32'sd420;
        mem[527] = -32'sd420;
        mem[528] = -32'sd420;
        mem[529] = -32'sd425;
        mem[530] = -32'sd415;
        mem[531] = -32'sd395;
        mem[532] = -32'sd390;
        mem[533] = -32'sd375;
        mem[534] = -32'sd360;
        mem[535] = -32'sd335;
        mem[536] = -32'sd330;
        mem[537] = -32'sd335;
        mem[538] = -32'sd325;
        mem[539] = -32'sd305;
        mem[540] = -32'sd305;
        mem[541] = -32'sd310;
        mem[542] = -32'sd305;
        mem[543] = -32'sd300;
        mem[544] = -32'sd300;
        mem[545] = -32'sd310;
        mem[546] = -32'sd310;
        mem[547] = -32'sd315;
        mem[548] = -32'sd305;
        mem[549] = -32'sd315;
        mem[550] = -32'sd325;
        mem[551] = -32'sd310;
        mem[552] = -32'sd305;
        mem[553] = -32'sd320;
        mem[554] = -32'sd325;
        mem[555] = -32'sd310;
        mem[556] = -32'sd295;
        mem[557] = -32'sd325;
        mem[558] = -32'sd330;
        mem[559] = -32'sd320;
        mem[560] = -32'sd320;
        mem[561] = -32'sd325;
        mem[562] = -32'sd350;
        mem[563] = -32'sd340;
        mem[564] = -32'sd330;
        mem[565] = -32'sd335;
        mem[566] = -32'sd360;
        mem[567] = -32'sd350;
        mem[568] = -32'sd350;
        mem[569] = -32'sd360;
        mem[570] = -32'sd355;
        mem[571] = -32'sd355;
        mem[572] = -32'sd350;
        mem[573] = -32'sd355;
        mem[574] = -32'sd350;
        mem[575] = -32'sd365;
        mem[576] = -32'sd350;
        mem[577] = -32'sd355;
        mem[578] = -32'sd370;
        mem[579] = -32'sd380;
        mem[580] = -32'sd360;
        mem[581] = -32'sd365;
        mem[582] = -32'sd365;
        mem[583] = -32'sd380;
        mem[584] = -32'sd370;
        mem[585] = -32'sd350;
        mem[586] = -32'sd350;
        mem[587] = -32'sd370;
        mem[588] = -32'sd365;
        mem[589] = -32'sd345;
        mem[590] = -32'sd340;
        mem[591] = -32'sd365;
        mem[592] = -32'sd360;
        mem[593] = -32'sd355;
        mem[594] = -32'sd355;
        mem[595] = -32'sd375;
        mem[596] = -32'sd355;
        mem[597] = -32'sd360;
        mem[598] = -32'sd360;
        mem[599] = -32'sd360;
        mem[600] = -32'sd360;
        mem[601] = -32'sd345;
        mem[602] = -32'sd355;
        mem[603] = -32'sd345;
        mem[604] = -32'sd345;
        mem[605] = -32'sd310;
        mem[606] = -32'sd305;
        mem[607] = -32'sd310;
        mem[608] = -32'sd305;
        mem[609] = -32'sd290;
        mem[610] = -32'sd275;
        mem[611] = -32'sd280;
        mem[612] = -32'sd275;
        mem[613] = -32'sd265;
        mem[614] = -32'sd245;
        mem[615] = -32'sd260;
        mem[616] = -32'sd275;
        mem[617] = -32'sd280;
        mem[618] = -32'sd265;
        mem[619] = -32'sd275;
        mem[620] = -32'sd280;
        mem[621] = -32'sd280;
        mem[622] = -32'sd275;
        mem[623] = -32'sd255;
        mem[624] = -32'sd240;
        mem[625] = -32'sd280;
        mem[626] = -32'sd310;
        mem[627] = -32'sd310;
        mem[628] = -32'sd360;
        mem[629] = -32'sd380;
        mem[630] = -32'sd380;
        mem[631] = -32'sd370;
        mem[632] = -32'sd385;
        mem[633] = -32'sd390;
        mem[634] = -32'sd395;
        mem[635] = -32'sd385;
        mem[636] = -32'sd385;
        mem[637] = -32'sd405;
        mem[638] = -32'sd400;
        mem[639] = -32'sd375;
        mem[640] = -32'sd390;
        mem[641] = -32'sd415;
        mem[642] = -32'sd405;
        mem[643] = -32'sd400;
        mem[644] = -32'sd405;
        mem[645] = -32'sd425;
        mem[646] = -32'sd475;
        mem[647] = -32'sd505;
        mem[648] = -32'sd525;
        mem[649] = -32'sd540;
        mem[650] = -32'sd645;
        mem[651] = -32'sd630;
        mem[652] = -32'sd575;
        mem[653] = -32'sd385;
        mem[654] = -32'sd270;
        mem[655] = 32'sd90;
        mem[656] = 32'sd370;
        mem[657] = 32'sd810;
        mem[658] = 32'sd860;
        mem[659] = 32'sd770;
        mem[660] = 32'sd65;
        mem[661] = -32'sd305;
        mem[662] = -32'sd520;
        mem[663] = -32'sd475;
        mem[664] = -32'sd390;
        mem[665] = -32'sd390;
        mem[666] = -32'sd410;
        mem[667] = -32'sd405;
        mem[668] = -32'sd385;
        mem[669] = -32'sd395;
        mem[670] = -32'sd405;
        mem[671] = -32'sd405;
        mem[672] = -32'sd400;
        mem[673] = -32'sd395;
        mem[674] = -32'sd410;
        mem[675] = -32'sd410;
        mem[676] = -32'sd395;
        mem[677] = -32'sd405;
        mem[678] = -32'sd405;
        mem[679] = -32'sd405;
        mem[680] = -32'sd390;
        mem[681] = -32'sd385;
        mem[682] = -32'sd395;
        mem[683] = -32'sd400;
        mem[684] = -32'sd400;
        mem[685] = -32'sd395;
        mem[686] = -32'sd395;
        mem[687] = -32'sd405;
        mem[688] = -32'sd400;
        mem[689] = -32'sd385;
        mem[690] = -32'sd375;
        mem[691] = -32'sd395;
        mem[692] = -32'sd390;
        mem[693] = -32'sd385;
        mem[694] = -32'sd385;
        mem[695] = -32'sd395;
        mem[696] = -32'sd385;
        mem[697] = -32'sd375;
        mem[698] = -32'sd385;
        mem[699] = -32'sd395;
        mem[700] = -32'sd390;
        mem[701] = -32'sd365;
        mem[702] = -32'sd375;
        mem[703] = -32'sd395;
        mem[704] = -32'sd380;
        mem[705] = -32'sd375;
        mem[706] = -32'sd380;
        mem[707] = -32'sd380;
        mem[708] = -32'sd375;
        mem[709] = -32'sd375;
        mem[710] = -32'sd375;

        rst_n = 1'b0; run = 1'b0; soft_rst = 1'b0; cap_len_in = 32'd4096;
        src_sel = 1'b0; adc_sample = 16'sd0; adc_valid = 1'b0;
        errs = 0; checks = 0;
        clear_stats;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        run = 1'b1;

        $display("========== ecg_core : dual data source (ROM / ADS1292) ==========");
        $display("*** TB BUILD CORE-2 ***  (711 samples inlined, no .hex file needed)");

        // ---- phase 0 : ROM player ----
        repeat (NSAMP*CLKS + 4000) @(posedge clk);
        run = 1'b0;                          // stop the sample stream so the
        repeat (8) @(posedge clk);           // capture counters settle mid-pair
        $display("--- source 0 : ROM player ---");
        check_all;

        // ---- phase 1 : the same samples pushed in through the ADS1292 port ----
        clear_stats;
        src_sel = 1'b1;
        soft_rst = 1'b1; repeat (5) @(negedge clk); soft_rst = 1'b0;
        repeat (3) @(negedge clk);
        run = 1'b1;
        // 64 extra samples wrap round like the real ROM loop, so the last beat's
        // CLT can finish falling below half peak.
        for (i = 0; i < NSAMP+64; i = i + 1) begin
            @(negedge clk); adc_sample = (i < NSAMP) ? mem[i] : mem[i-NSAMP]; adc_valid = 1'b1;
            @(negedge clk); adc_valid = 1'b0;
            repeat (CLKS-2) @(negedge clk);
        end
        repeat (4000) @(posedge clk);
        run = 1'b0;
        repeat (8) @(posedge clk);
        $display("--- source 1 : ADS1292 port ---");
        check_all;

        $display("---------------------------------------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errs);
        if (errs == 0) $display("  RESULT: PASS");
        else           $display("  RESULT: FAIL");
        $display("===========================================================================");
        $finish;
    end

endmodule
`default_nettype wire



