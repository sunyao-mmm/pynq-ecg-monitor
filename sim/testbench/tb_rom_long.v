`timescale 1ns / 1ps
`default_nettype none
// Long-running ROM regression: feed the same ROM repeatedly and report how
// detections change after the adaptive threshold has seen many loop seams.
module tb_rom_long;
    parameter integer CLKS    = 100;
    parameter integer NSAMP   = 711;
    parameter integer RUNSAMP = 10000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg run = 1'b0;
    reg soft_rst = 1'b0;
    reg [31:0] cap_len_in = 32'd2000 | 32'h8000_0000;
    reg src_sel = 1'b0;
    reg signed [15:0] adc_sample = 0;
    reg adc_valid = 0;

    wire [9:0] rom_addr;
    reg signed [15:0] rom_data = 0;
    wire cap_we;
    wire [11:0] cap_addr;
    wire [31:0] cap_data;
    wire [31:0] st_clt_now, st_r_index, st_rr_samples, st_beat_count, st_rr_bad_cnt;
    wire [15:0] st_r_amp, st_bpm;
    wire st_cap_done;

    reg signed [15:0] mem [0:1023];
    reg signed [15:0] rom_q1;
    reg [8*256-1:0] fname;
    reg [31:0] peaks [0:1023];
    integer npeaks = 0;
    integer i;
    integer counts [0:31];

    ecg_core #(
        .CLK_PER_SAMPLE(CLKS),
        .ROM_AW(10),
        .CAP_AW(12),
        .ROM_LEN(NSAMP)
    ) dut (
        .clk(clk), .rst_n(rst_n), .run(run), .soft_rst(soft_rst),
        .cap_len_in(cap_len_in), .src_sel(src_sel),
        .adc_sample(adc_sample), .adc_valid(adc_valid),
        .rom_addr(rom_addr), .rom_data(rom_data),
        .cap_we(cap_we), .cap_addr(cap_addr), .cap_data(cap_data),
        .st_clt_now(st_clt_now), .st_r_index(st_r_index),
        .st_r_amp(st_r_amp), .st_bpm(st_bpm),
        .st_rr_samples(st_rr_samples), .st_beat_count(st_beat_count),
        .st_rr_bad_cnt(st_rr_bad_cnt), .st_cap_done(st_cap_done)
    );

    always @(posedge clk) begin
        rom_q1 <= mem[rom_addr];
        rom_data <= rom_q1;
    end

    always @(posedge clk) begin
        if (rst_n && dut.u_det.r_valid && npeaks < 1024) begin
            peaks[npeaks] = dut.u_det.r_index;
            npeaks = npeaks + 1;
        end
    end

    initial begin
        if (!$value$plusargs("HEXFILE=%s", fname))
            fname = "ecg_rom_208.hex";
        $readmemh(fname, mem);
        for (i = 0; i < 32; i = i + 1)
            counts[i] = 0;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);
        run = 1'b1;
        repeat (RUNSAMP * CLKS) @(negedge clk);
        run = 1'b0;
        repeat (20) @(negedge clk);

        for (i = 0; i < npeaks; i = i + 1)
            if (peaks[i] / NSAMP < 32)
                counts[peaks[i] / NSAMP] = counts[peaks[i] / NSAMP] + 1;

        $display("ROM=%0s samples=%0d loops=%0d", fname, RUNSAMP, RUNSAMP/NSAMP);
        $display("beat_count=%0d bpm=%0d last_rr=%0d rr_bad=%0d npeaks=%0d",
                 st_beat_count, st_bpm, st_rr_samples, st_rr_bad_cnt, npeaks);
        $write("peaks:");
        for (i = 0; i < npeaks; i = i + 1)
            $write(" %0d", peaks[i]);
        $write("\nper_loop:");
        for (i = 0; i < (RUNSAMP/NSAMP); i = i + 1)
            $write(" %0d", counts[i]);
        $write("\n");
        $display("RESULT: PASS");
        $finish;
    end
endmodule

`default_nettype wire
