`timescale 1ns / 1ps
`default_nettype none
// heart_rate.v : RR interval + bpm from R peaks. bpm = round(60*FS_HZ/rr) via a 16-step shift/subtract divider (no divider IP).
module heart_rate #(
    parameter integer FS_HZ   = 250,      // ECG sample rate
    parameter integer BPM_MIN = 30,       // physiological window
    parameter integer BPM_MAX = 200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        r_valid,           // one pulse per detected R peak
    input  wire [31:0] r_index,           // position of that peak, in input samples
    output reg  [15:0] bpm,               // heart rate
    output reg         bpm_valid,         // 1 clock pulse when bpm is updated
    output reg  [31:0] rr_samples,        // last RR interval in samples
    output reg  [31:0] rr_avg,            // average of the last 4 RR intervals
    output reg         rr_bad,            // last RR was outside the window
    output reg  [31:0] beat_count
);

    localparam integer RR_MIN_I = (60 * FS_HZ) / BPM_MAX;   // 108 samples = 200 bpm
    localparam integer RR_MAX_I = (60 * FS_HZ) / BPM_MIN;   // 720 samples =  30 bpm
    localparam [15:0]  NUM16    = 60 * FS_HZ;               // 21600
    localparam integer DIV_W    = 16;

    wire [31:0] rr_min_w = RR_MIN_I;        // explicit uint32 copies: the compare below
    wire [31:0] rr_max_w = RR_MAX_I;        // is then plain unsigned arithmetic

    reg [31:0] prev_index;
    reg        primed;                      // first R peak seen
    reg        avg_primed;                  // 4-beat history filled
    reg [31:0] rr_hist [0:3];
    reg [1:0]  rr_ptr;
    reg [31:0] rr_sum;
    reg [31:0] rr;                          // last valid interval
    reg        start_div;

    wire [31:0] rr_new   = r_index - prev_index;
    wire        order_ok = (r_index >= prev_index);
    wire        rr_in    = order_ok && (rr_new >= rr_min_w) && (rr_new <= rr_max_w);

    // ---------------- 4-beat median (for bpm) ----------------
    // 单拍被早搏或假峰污染时，中位数比"最后一个 RR"稳得多。
    // 这里把"新来的这一拍"先塞进历史位置，再做 4 元素排序网络取中间两个的平均。
    wire [31:0] h0 = (rr_ptr == 2'd0) ? rr_new : rr_hist[0];
    wire [31:0] h1 = (rr_ptr == 2'd1) ? rr_new : rr_hist[1];
    wire [31:0] h2 = (rr_ptr == 2'd2) ? rr_new : rr_hist[2];
    wire [31:0] h3 = (rr_ptr == 2'd3) ? rr_new : rr_hist[3];

    wire [31:0] a01lo = (h0 < h1) ? h0 : h1;   wire [31:0] a01hi = (h0 < h1) ? h1 : h0;
    wire [31:0] a23lo = (h2 < h3) ? h2 : h3;   wire [31:0] a23hi = (h2 < h3) ? h3 : h2;
    wire [31:0] b02lo = (a01lo < a23lo) ? a01lo : a23lo;
    wire [31:0] b02hi = (a01lo < a23lo) ? a23lo : a01lo;
    wire [31:0] b13lo = (a01hi < a23hi) ? a01hi : a23hi;
    wire [31:0] b13hi = (a01hi < a23hi) ? a23hi : a01hi;
    wire [31:0] med_lo = (b02lo < b13lo) ? b13lo : b02lo;   // 第 2 小
    wire [31:0] med_hi = (b02hi < b13hi) ? b02hi : b13hi;   // 第 3 小
    wire [31:0] rr_med = (med_lo + med_hi) >> 1;

    // ---------------- serial divider state ----------------
    reg [DIV_W-1:0] dend_sh, dsor, quot;
    reg [DIV_W:0]   rem;
    reg [4:0]       dstep;
    reg             dbusy;

    wire [DIV_W:0] rem_next = {rem[DIV_W-1:0], dend_sh[DIV_W-1]};
    wire [DIV_W:0] dsor_ext = {1'b0, dsor};
    wire           ge       = (rem_next >= dsor_ext);

    // 4-beat sum, built combinationally so that no array is read in a
    // continuous assignment (v1 did that; it is not legal Verilog-2001)
    reg [31:0] sum_c;
    always @* sum_c = rr_sum - rr_hist[rr_ptr] + rr_new;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_index <= 32'd0;
            primed     <= 1'b0;
            avg_primed <= 1'b0;
            rr_hist[0] <= 32'd0; rr_hist[1] <= 32'd0;
            rr_hist[2] <= 32'd0; rr_hist[3] <= 32'd0;
            rr_ptr     <= 2'd0;
            rr_sum     <= 32'd0;
            rr         <= 32'd0;
            start_div  <= 1'b0;
            bpm        <= 16'd0;
            bpm_valid  <= 1'b0;
            rr_samples <= 32'd0;
            rr_avg     <= 32'd0;
            rr_bad     <= 1'b0;
            beat_count <= 32'd0;
            dend_sh    <= {DIV_W{1'b0}};
            dsor       <= {DIV_W{1'b0}};
            rem        <= {(DIV_W+1){1'b0}};
            quot       <= {DIV_W{1'b0}};
            dstep      <= 5'd0;
            dbusy      <= 1'b0;
        end
        else begin
            bpm_valid <= 1'b0;
            rr_bad    <= 1'b0;
            start_div <= 1'b0;

            // ---------------- new R peak ----------------
            if (r_valid) begin
                beat_count <= beat_count + 32'd1;
                if (!primed) begin
                    primed     <= 1'b1;
                    prev_index <= r_index;
                end
                else begin
                    prev_index <= r_index;
                    if (rr_in) begin
                        // 第一拍历史还是空的，中位数会算成 0（后面就除以 0 了），
                        // 所以第一次直接用新值，之后才用 4 拍中位数。
                        rr         <= avg_primed ? rr_med : rr_new;
                        rr_samples <= rr_new;
                        if (!avg_primed) begin
                            avg_primed <= 1'b1;
                            rr_hist[0] <= rr_new; rr_hist[1] <= rr_new;
                            rr_hist[2] <= rr_new; rr_hist[3] <= rr_new;
                            rr_ptr     <= 2'd1;
                            rr_sum     <= rr_new << 2;
                            rr_avg     <= rr_new;
                        end
                        else begin
                            rr_hist[rr_ptr] <= rr_new;
                            rr_ptr          <= rr_ptr + 2'd1;
                            rr_sum          <= sum_c;
                            rr_avg          <= sum_c >> 2;
                        end
                        start_div <= 1'b1;
                    end
                    else begin
                        rr_bad <= 1'b1;
                    end
                end
            end

            // ---------------- serial divider: (21600 + rr/2) / rr ----------------
            if (dbusy) begin
                if (dstep == DIV_W) begin
                    dbusy     <= 1'b0;
                    bpm       <= quot;
                    bpm_valid <= 1'b1;
                end
                else begin
                    rem     <= ge ? (rem_next - dsor_ext) : rem_next;
                    quot    <= {quot[DIV_W-2:0], ge};
                    dend_sh <= {dend_sh[DIV_W-2:0], 1'b0};
                    dstep   <= dstep + 5'd1;
                end
            end
            else if (start_div) begin
                dsor    <= rr[15:0];                 // rr 已经是 4 拍中位数
                dend_sh <= NUM16 + (rr[15:0] >> 1);
                rem     <= {(DIV_W+1){1'b0}};
                quot    <= {DIV_W{1'b0}};
                dstep   <= 5'd0;
                dbusy   <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire

