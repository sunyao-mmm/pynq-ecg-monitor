`timescale 1ns / 1ps
`default_nettype none
// ecg_core.v : 360 Hz ROM player + FIR + CLT + heart rate + capture writer, inside the block design.
// ROM latency is absorbed by waiting ROM_SETTLE clocks; cap_data = {r_valid, clt_out[30:0]}.
module ecg_core #(
    parameter integer CLK_PER_SAMPLE = 400000,   // 100 MHz / 250 Hz
    parameter integer ROM_LEN        = 711,      // real ROM samples (1024*250/360)
    parameter integer ROM_AW         = 10,       // 1024 samples
    parameter integer CAP_AW         = 12,       // 4096 samples of capture buffer
    parameter integer ROM_SETTLE     = 4         // clocks to wait for the ROM data before use
    ,parameter integer SETTLE        = 96        // 实时通路前多少个采样点不参与阈值学习（等启动瞬态过去）
    ,parameter integer CAL_FIRST     = 1         // 实时通路第一次判定只用于定标（不报 R 峰）
                                                 // (any BMG read latency 1..4 works)
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_RESET rst_n, FREQ_HZ 20000000, PHASE 0.0" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,

    // ---- control in, from ecg_axil ----
    input  wire        run,              // ecg_axil ctrl_run
    input  wire        soft_rst,         // ecg_axil ctrl_soft_rst
    input  wire [31:0] cap_len_in,       // ecg_axil cap_len

    // ---- data source: 0 = ROM player, 1 = ADS1292 ----
    input  wire               src_sel,
    input  wire signed [15:0] adc_sample,
    input  wire               adc_valid,  // one pulse per ADS1292 sample

    // ---- ROM interface (Block Memory Generator, 1 clock read latency) ----
    output reg  [ROM_AW-1:0]        rom_addr,
    input  wire signed [15:0]       rom_data,

    // ---- capture buffer write side (BNG round 2; leave unconnected in round 1) ----
    output reg                      cap_we,
    output reg  [CAP_AW-1:0]        cap_addr,
    output reg  [31:0]              cap_data,

    // ---- status out, to ecg_axil (same names as the stub) ----
    output wire [31:0] st_clt_now,
    output wire [31:0] st_r_index,
    output wire [15:0] st_r_amp,
    output wire [15:0] st_bpm,
    output wire [31:0] st_rr_samples,
    output wire [31:0] st_beat_count,
    output wire [31:0] st_rr_bad_cnt,
    output wire        st_cap_done
);

    localparam integer CAP_DEPTH   = (1 << CAP_AW);        // 4096 words
    localparam integer CAP_MAX_SMP = CAP_DEPTH / 2;        // 2048 samples (2 words each)
    localparam integer CAP_CONT_MAX_SMP = CAP_MAX_SMP - 1; // address 0 stays unused

    // ---------------- reset / run gating ----------------
    reg  [31:0] div_cnt;
    reg         ce_smp;                  // one clock pulse per ECG sample
    reg         rom_ce;                  // ce_smp delayed one clock (ROM data valid)
    reg         cap_done;
    reg  [CAP_AW-1:0] cap_wr_pos;         // completed sample position in continuous ring

    wire det_rst_n = rst_n & ~soft_rst;  // the PS can restart the chain with CTRL bit1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 32'd0;
            ce_smp  <= 1'b0;
        end
        else if (run && !soft_rst) begin
            if (div_cnt == CLK_PER_SAMPLE-1) begin
                div_cnt <= 32'd0;
                ce_smp  <= 1'b1;
            end
            else begin
                div_cnt <= div_cnt + 32'd1;
                ce_smp  <= 1'b0;
            end
        end
        else begin
            div_cnt <= 32'd0;
            ce_smp  <= 1'b0;
        end
    end

    // ---------------- ROM address counter + data settling ----------------
    //
    // The Block Memory Generator reports its own read latency (1, 2, 3 ... clocks).
    // Instead of hard coding it, this logic holds the address steady and waits
    // ROM_SETTLE clocks before using rom_data -- any latency up to ROM_SETTLE is
    // then correct, whatever the IP was configured with.
    //
    reg  [3:0] settle_cnt;
    reg        rom_busy;
    wire [ROM_AW-1:0] rom_addr_nxt = (rom_addr == ROM_LEN-1) ? {ROM_AW{1'b0}}
                                                                  : (rom_addr + 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_addr   <= {ROM_AW{1'b0}};
            rom_ce     <= 1'b0;
            settle_cnt <= 4'd0;
            rom_busy   <= 1'b0;
        end
        else if (soft_rst) begin
            rom_addr   <= {ROM_AW{1'b0}};
            rom_ce     <= 1'b0;
            settle_cnt <= 4'd0;
            rom_busy   <= 1'b0;
        end
        else begin
            rom_ce <= 1'b0;
            if (!rom_busy) begin
                if (ce_smp) begin                 // a new sample is due: address is already set
                    settle_cnt <= 4'd0;
                    rom_busy   <= 1'b1;
                end
            end
            else if (settle_cnt == ROM_SETTLE-1) begin
                rom_ce     <= 1'b1;               // rom_data is valid now -> let the chain sample it
                rom_addr   <= rom_addr_nxt;       // get ready for the next sample
                rom_busy   <= 1'b0;
            end
            else begin
                settle_cnt <= settle_cnt + 4'd1;
            end
        end
    end

    // ---------------- ADS1292 self-check report ----------------
    //
    // ads1292_spi reads the chip's ID register back after configuring it and
    // then pushes three "diagnostic samples" out of its sample port:
    //     0xA5xx  chip ID     (0x53 = ADS1292, 0x73 = ADS1292R,
    //                          0x5A = DOUT/DIN shorted together -> loopback ok)
    //     0xA6xx  frames read so far (low 8 bits)
    //     0xA7xx  status byte of the last frame (normally 0xC0)
    //
    // These are NOT ECG, so they are swallowed here - the marker value never
    // enters the notch/FIR/CLT chain (a 5-40 Hz band-pass would smear the byte
    // away anyway).  The three bytes are parked instead and handed to the PS
    // through the CLT_NOW register (0x08) while run = 0:
    //
    //     0x08 = 0xEC_ss_cc_ii   (ii = chip ID, cc = frame count, ss = status)
    //            0x00000000      = no diagnostic sample seen yet
    //            the live CLT value as soon as run = 1 (normal operation)
    //
    // So "load the overlay with run = 0, read 0x08" answers "is the chip
    // answering?" without disturbing anything else.
    reg [7:0] dg_id, dg_cnt, dg_stat;
    reg       dg_seen;

    wire [7:0] adc_hi   = adc_sample[15:8];
    wire       adc_mark = adc_valid & (adc_hi == 8'hA5 || adc_hi == 8'hA6
                                       || adc_hi == 8'hA7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dg_id <= 8'h00; dg_cnt <= 8'h00; dg_stat <= 8'h00;
            dg_seen <= 1'b0;
        end
        else if (adc_mark) begin
            dg_seen <= 1'b1;
            case (adc_hi)
                8'hA5:   dg_id   <= adc_sample[7:0];
                8'hA6:   dg_cnt  <= adc_sample[7:0];
                default: dg_stat <= adc_sample[7:0];
            endcase
        end
    end

    // ---------------- the algorithm chain ----------------
    // ponytail: one 2:1 mux picks the source; both paths still run, the unused
    // one's strobe is simply ignored.  Diagnostic markers are dropped from the
    // strobe so that they cannot fake an R peak in the CLT detector.
    wire               det_ce = src_sel ? (adc_valid & ~adc_mark) : rom_ce;
    wire signed [15:0] det_x  = src_sel ? adc_sample : rom_data;

    wire signed [31:0] clt_out;
    wire               clt_valid;
    wire               r_valid;
    wire [31:0]        r_index;
    wire signed [15:0] r_amp;
    wire signed [15:0] det_y;      // band-passed ECG (FIR output), for the PS display

    ecg_detect_top #(
        .FIR_TAPS(65), .FIR_DELAY(32), .CLT_W(21), .C_CONST(2),
        .LEARN(30), .SEARCH(22), .REFRACT(100), .REL_PERIOD(250),
        .DATA_W(16), .ACC_W(32)
    ) u_det (
        // ROM 回放：settle_sel = 0（第一拍就要判出来，自检才对得上）
        // 实时 ADS1292：settle_sel = SETTLE（跳过启动瞬态再学阈值）
        .clk(clk), .rst_n(det_rst_n), .ce(det_ce), .x(det_x),
        .settle_sel(src_sel ? SETTLE[15:0] : 16'd0),
        .cal_first(src_sel & CAL_FIRST[0]),
        .y(det_y), .y_valid(),
        .clt_out(clt_out), .clt_valid(clt_valid),
        .r_valid(r_valid), .r_index(r_index), .r_amp(r_amp)
    );

    wire [15:0] hr_bpm;
    wire        hr_bpm_valid;
    wire [31:0] hr_rr_samples, hr_rr_avg;
    wire        hr_rr_bad;
    wire [31:0] hr_beat_count;

    heart_rate #(.FS_HZ(250), .BPM_MIN(30), .BPM_MAX(200)) u_hr (
        .clk(clk), .rst_n(det_rst_n), .r_valid(r_valid), .r_index(r_index),
        .bpm(hr_bpm), .bpm_valid(hr_bpm_valid),
        .rr_samples(hr_rr_samples), .rr_avg(hr_rr_avg),
        .rr_bad(hr_rr_bad), .beat_count(hr_beat_count)
    );

    // ---------------- rr_bad pulse counter ----------------
    reg [31:0] rr_bad_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            rr_bad_cnt <= 32'd0;
        else if (soft_rst)     rr_bad_cnt <= 32'd0;
        else if (hr_rr_bad)    rr_bad_cnt <= rr_bad_cnt + 32'd1;
    end

    // ---------------- capture buffer writer ----------------
    // TWO 32-bit words are stored for every sample, so that the PS can draw the
    // real ECG waveform and the CLT curve side by side:
    //   even word address : { 15'b0, r_valid, y[15:0] }   band-passed ECG + R flag
    //   odd  word address : clt_out                       curve length transform
    // CAP_LEN is still programmed in SAMPLES; the word limit is 2 * CAP_LEN and is
    // clamped to the 4096-word buffer (= 2048 samples = 8.2 s at 250 Hz).
    localparam [CAP_AW:0] CAP_WORDS  = (1 << CAP_AW);

    // Bit 31 of CAP_LEN selects continuous ring mode.  When it is clear, the
    // original capture-and-stop behavior is preserved for pynq_ecg.py.
    wire                 cont_mode    = cap_len_in[31];
    wire [31:0]          cap_len_normal = {1'b0, cap_len_in[30:0]};
    wire [CAP_AW-1:0]    cap_len_smp  = cap_len_in[CAP_AW-1:0];
    wire [CAP_AW:0]      cont_smp_raw = {1'b0, cap_len_smp};
    wire [CAP_AW:0]      cont_smp_eff = (cont_smp_raw == 0 || cont_smp_raw > CAP_CONT_MAX_SMP)
                                         ? CAP_CONT_MAX_SMP : cont_smp_raw;
    wire [CAP_AW:0]      normal_limit_w = (cap_len_normal == 0 || cap_len_normal > CAP_MAX_SMP)
                                         ? CAP_WORDS : ({1'b0, cap_len_smp} << 1);
    wire [CAP_AW:0]      cap_limit_w    = cont_mode ? (cont_smp_eff << 1) : normal_limit_w;
    wire [CAP_AW:0] cap_addr_w  = {1'b0, cap_addr} + 1'b1;
    reg             cap_ph;      // 0 = next word is the waveform, 1 = next is the CLT

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_we    <= 1'b0;
            cap_addr  <= {CAP_AW{1'b0}};
            cap_data  <= 32'd0;
            cap_done  <= 1'b0;
            cap_ph    <= 1'b0;
            cap_wr_pos <= {CAP_AW{1'b0}};
        end
        else begin
            cap_we <= 1'b0;
            if (soft_rst) begin
                cap_addr <= {CAP_AW{1'b0}};
                cap_done <= 1'b0;
                cap_ph   <= 1'b0;
                cap_wr_pos <= {CAP_AW{1'b0}};
            end
            else if (!cap_done || cont_mode) begin
                if (!cap_ph && clt_valid) begin          // word 0 : the waveform
                    cap_we     <= 1'b1;
                    cap_data   <= {15'd0, r_valid, det_y};
                    // BRAM samples the registered address one cycle later.
                    // After the CLT word fills the last slot, wrap here so the
                    // next waveform goes to address 1, not past the ring.
                    cap_addr   <= (cont_mode && cap_addr >= cap_limit_w)
                                  ? {{(CAP_AW-1){1'b0}}, 1'b1}
                                  : cap_addr_w[CAP_AW-1:0];
                    cap_ph     <= 1'b1;
                    if (!cont_mode && cap_addr_w >= cap_limit_w)
                        cap_done <= 1'b1;
                end
                else if (cap_ph) begin                   // word 1 : the CLT value
                    cap_we     <= 1'b1;
                    cap_data   <= clt_out;
                    cap_ph     <= 1'b0;
                    if (cont_mode) begin
                        cap_addr <= cap_addr_w[CAP_AW-1:0];
                        cap_wr_pos <= (cap_wr_pos + 1'b1 >= cont_smp_eff)
                                      ? {CAP_AW{1'b0}}
                                      : cap_wr_pos + 1'b1;
                    end
                    else begin
                        cap_addr <= cap_addr_w[CAP_AW-1:0];
                        if (cap_addr_w >= cap_limit_w) cap_done <= 1'b1;
                    end
                end
            end
        end
    end

    // ---------------- status to the register window ----------------
    // 0x08 CLT_NOW : normal mode returns the live CLT value.  Continuous mode
    // returns the completed-sample ring position in bits 27:16 and leaves the
    // lower bits clear; the web client reads waveform/CLT from the capture RAM.
    assign st_clt_now    = run ? (cont_mode ? {4'd0, cap_wr_pos, 16'd0} : clt_out)
                               : (dg_seen ? {8'hEC, dg_stat, dg_cnt, dg_id} : 32'd0);
    assign st_r_index    = r_index;
    assign st_r_amp      = r_amp;
    assign st_bpm        = hr_bpm;
    assign st_rr_samples = hr_rr_samples;
    assign st_beat_count = hr_beat_count;
    assign st_rr_bad_cnt = rr_bad_cnt;
    assign st_cap_done   = cap_done;

endmodule
`default_nettype wire





