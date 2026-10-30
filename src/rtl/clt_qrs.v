`timescale 1ns / 1ps
`default_nettype none
// clt_qrs.v : R-peak detector, Curve Length Transform (CLT) + adaptive threshold + argmax lookback.
module clt_qrs #(
    parameter integer W       = 21,   // CLT window length in samples (QRS width ~80-100ms)
    parameter integer C_CONST = 2,    // CLT constant term c
    parameter integer LEARN   = 30,   // threshold warm-up window after settle
    parameter integer SEARCH  = 22,   // R-peak look-back depth (samples)
    parameter integer REFRACT = 100,  // refractory period in samples (400 ms @ 250 Hz)
    parameter integer DATA_W  = 16,   // input sample width
    parameter integer ACC_W   = 32,   // CLT accumulator width
    parameter integer REL_PERIOD = 250, // threshold re-learn period in samples (0 = off)
    parameter integer LOW_THR_NUM = 12, // recovery threshold 12/32 = 0.375
    parameter integer RR_MIN = 108,     // shortest accepted reference RR (200 bpm)
    parameter integer RR_MAX = 720      // longest accepted reference RR (30 bpm)
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     ce,          // sample-rate enable, 1 pulse per sample
    input  wire signed [DATA_W-1:0] x,           // ECG sample (FIR output)
    input  wire                     valid_in,    // sample valid, in step with ce
    input  wire [15:0]              settle_sel,  // 学习起点：ROM=0，实时=96
    input  wire                     cal_first,   // 1 = 上电后第一次判到的只用来定标，不报 R 峰
    output reg  signed [ACC_W-1:0]  clt_out,     // CLT curve length, for PS display
    output reg                      clt_valid,
    output reg                      r_valid,     // R-peak pulse, 1 ce cycle wide
    output reg  [31:0]              r_index,     // R-peak sample index
    output reg  signed [DATA_W-1:0] r_amp        // R-peak amplitude
);
    localparam integer THR_NUM = 13;   // 13/32 = 0.406
    localparam integer TH_OFF  = 5;

    integer k;

    // ---------------- input sample delay line, for R-peak look-back ----------------
    reg signed [DATA_W-1:0] x_dl [0:SEARCH-1];
    reg signed [DATA_W-1:0] x_d1;

    // ---------------- CLT: W-deep delay line of x2 ----------------
    reg signed [ACC_W-1:0] x2_dl [0:W-1];
    reg signed [ACC_W-1:0] clt_acc;

    // ---------------- detection state ----------------
    reg [31:0]              n;            // sample counter
    reg signed [ACC_W-1:0]  learn_max;
    reg signed [ACC_W-1:0]  thr;
    reg signed [ACC_W-1:0]  est;          // CLT peak amplitude estimate
    reg signed [ACC_W-1:0]  run_max;      // CLT max since the current rise started
    reg                     thr_init;
    reg                     armed;
    reg [31:0]              refract_cnt;
    reg [31:0]              last_peak_index;
    reg [31:0]              rr_est;
    reg                     peak_seen;
    reg                     rr_est_valid;
    reg signed [ACC_W-1:0]  win_max;      // max CLT since the last re-learn boundary
    reg [31:0]              rel_cnt;
    reg                     cal_done;     // 第一次定标已经用掉了

    // ---------------- CLT combinational path ----------------
    wire signed [ACC_W-1:0] x_ext   = {{(ACC_W-DATA_W){x[DATA_W-1]}}, x};
    wire signed [ACC_W-1:0] xd_ext  = {{(ACC_W-DATA_W){x_d1[DATA_W-1]}}, x_d1};
    wire signed [ACC_W-1:0] diff    = x_ext - xd_ext;
    wire signed [ACC_W-1:0] adiff   = diff[ACC_W-1] ? (~diff + 1'b1) : diff;
    wire signed [ACC_W-1:0] x2      = C_CONST + (adiff <<< 2);   // c + 4*|x(n)-x(n-1)|
    wire signed [ACC_W-1:0] x4      = x2_dl[W-1];                // x2(n-W)
    wire signed [ACC_W-1:0] clt_nxt = clt_acc + x2 - x4;         // sliding-window recurrence

    // ---------------- fixed-window argmax over {x(n) .. x(n-SEARCH)} ----------------
    // offset convention: off = 0 -> current sample, off = j+1 -> x_dl[j]
    reg  signed [DATA_W-1:0] best_val;
    reg  [31:0]              best_off;
    integer j;
    always @* begin
        best_val = x;
        best_off = 32'd0;
        for (j = 0; j < SEARCH; j = j + 1) begin
            if (x_dl[j] > best_val) begin
                best_val = x_dl[j];
                best_off = j + 1;
            end
        end
    end

    // ---------------- decision ----------------
    wire signed [ACC_W-1:0] est_nxt = (est + est + est + run_max) >>> 2;   // (3*est+run_max)/4
    wire signed [ACC_W-1:0] thr_nxt = (est_nxt * THR_NUM) >>> TH_OFF;      // 0.4 * est
    wire signed [ACC_W-1:0] thr_low = (est * LOW_THR_NUM) >>> TH_OFF;
    wire signed [ACC_W-1:0] est_rel = (est + win_max) >>> 1;
    wire signed [ACC_W-1:0] thr_rel = (est_rel * THR_NUM) >>> TH_OFF;
    wire signed [ACC_W-1:0] win_cap    = (win_max > (est + (est >>> 1))) ? (est + (est >>> 1)) : win_max;
    wire signed [ACC_W-1:0] est_relearn = (est + win_cap) >>> 1;
    wire signed [ACC_W-1:0] thr_relearn = (est_relearn * THR_NUM) >>> TH_OFF;

    wire [31:0] settle_eff = {16'd0, settle_sel};
    wire [31:0] candidate_index = n - best_off;
    wire [31:0] since_last_peak = candidate_index - last_peak_index;
    wire [31:0] recovery_start = rr_est_valid ? (rr_est >>> 1) : REFRACT;
    wire [31:0] recovery_end = rr_est_valid
                               ? (rr_est + (rr_est >>> 1)) : RR_MAX;
    // After the refractory interval and around the expected next beat, allow
    // one lower-threshold search.  The normal threshold remains unchanged.
    wire recovery_window = peak_seen && (refract_cnt == 0)
                           && (since_last_peak >= recovery_start)
                           && (since_last_peak <= recovery_end);
    wire signed [ACC_W-1:0] arm_threshold = recovery_window ? thr_low : thr;
    wire peak_cond  = armed && (clt_nxt < (run_max >>> 1));   // CLT fell below half its peak
    wire detect_now = (n >= settle_eff + LEARN) && thr_init && (refract_cnt == 0) && peak_cond;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < SEARCH; k = k + 1) x_dl[k]  <= {DATA_W{1'b0}};
            for (k = 0; k < W;      k = k + 1) x2_dl[k] <= {ACC_W{1'b0}};
            x_d1        <= {DATA_W{1'b0}};
            clt_acc     <= {ACC_W{1'b0}};
            clt_out     <= {ACC_W{1'b0}};
            clt_valid   <= 1'b0;
            n           <= 32'd0;
            learn_max   <= {ACC_W{1'b0}};
            thr         <= {ACC_W{1'b0}};
            est         <= {ACC_W{1'b0}};
            run_max     <= {ACC_W{1'b0}};
            thr_init    <= 1'b0;
            armed       <= 1'b0;
            refract_cnt <= 32'd0;
            last_peak_index <= 32'd0;
            rr_est      <= 32'd0;
            peak_seen   <= 1'b0;
            rr_est_valid <= 1'b0;
            win_max     <= {ACC_W{1'b0}};
            rel_cnt     <= 32'd0;
            cal_done    <= 1'b0;
            r_valid     <= 1'b0;
            r_index     <= 32'd0;
            r_amp       <= {DATA_W{1'b0}};
        end
        else if (ce && valid_in) begin
            // ---- datapath ----
            x_d1 <= x;
            for (k = SEARCH-1; k > 0; k = k - 1) x_dl[k] <= x_dl[k-1];
            x_dl[0] <= x;
            for (k = W-1; k > 0; k = k - 1) x2_dl[k] <= x2_dl[k-1];
            x2_dl[0] <= x2;
            clt_acc   <= clt_nxt;
            clt_out   <= clt_nxt;
            clt_valid <= 1'b1;
            n         <= n + 1'b1;

            r_valid <= 1'b0;
            if (refract_cnt != 0) refract_cnt <= refract_cnt - 1'b1;
            if (n < settle_eff) begin
            end
            else if (n < settle_eff + LEARN) begin
                if (clt_nxt > learn_max) learn_max <= clt_nxt;
            end
            else if (!thr_init) begin
                thr      <= (learn_max * THR_NUM) >>> TH_OFF;
                est      <= learn_max;
                thr_init <= 1'b1;
                armed    <= 1'b0;
                run_max  <= {ACC_W{1'b0}};
            end
            // ---- per-beat detection ----
            else if (refract_cnt == 0) begin
                if (detect_now) begin
                    if (cal_first && !cal_done) begin                       
                        cal_done    <= 1'b1;
                        est         <= (learn_max != 0 && run_max > (learn_max <<< 1))
                                       ? (learn_max <<< 1) : run_max;
                        thr         <= (((learn_max != 0 && run_max > (learn_max <<< 1))
                                       ? (learn_max <<< 1) : run_max) * THR_NUM) >>> TH_OFF;
                        armed       <= 1'b0;
                        run_max     <= {ACC_W{1'b0}};
                        refract_cnt <= REFRACT;
                        last_peak_index <= candidate_index;
                        peak_seen   <= 1'b1;
                    end
                    else begin
                        r_valid     <= 1'b1;
                        r_index     <= n - best_off;
                        r_amp       <= best_val;
                        armed       <= 1'b0;
                        run_max     <= {ACC_W{1'b0}};
                        refract_cnt <= REFRACT;
                        if (peak_seen) begin
                            if (candidate_index >= last_peak_index) begin
                                if ((candidate_index - last_peak_index) >= RR_MIN
                                    && (candidate_index - last_peak_index) <= RR_MAX) begin
                                    if (!rr_est_valid) begin
                                        rr_est <= candidate_index - last_peak_index;
                                        rr_est_valid <= 1'b1;
                                    end
                                    else begin
                                        rr_est <= ((rr_est << 1) + rr_est
                                                   + (candidate_index - last_peak_index)) >>> 2;
                                    end
                                end
                            end
                        end
                        last_peak_index <= candidate_index;
                        peak_seen   <= 1'b1;
                        if (run_max > est)
                            est <= (est == 0) ? run_max
                                 : ((run_max > (est + (est >>> 1))) ? (est + (est >>> 1)) : run_max);
                        else
                            est <= est_nxt;
                        thr         <= thr_nxt;
                    end
                end
                else if (clt_nxt > arm_threshold) begin
                    if (clt_nxt > run_max) begin
                        run_max <= clt_nxt;
                        armed   <= 1'b1;
                    end
                end
                else if (clt_nxt < (run_max >>> 1)) begin                 
                    armed <= 1'b0;
                end
            end

            // ---- periodic re-learning of the amplitude reference ----
            if (REL_PERIOD > 0 && n >= settle_eff) begin
                if (rel_cnt == REL_PERIOD - 1) begin
                    est     <= est_relearn;
                    thr     <= thr_relearn;
                    win_max <= clt_nxt;
                    rel_cnt <= 32'd0;
                end
                else begin
                    rel_cnt <= rel_cnt + 32'd1;
                    if (clt_nxt > win_max) win_max <= clt_nxt;
                end
            end
        end
        else begin
            clt_valid <= 1'b0;
            r_valid   <= 1'b0;
        end
    end

endmodule
`default_nettype wire
