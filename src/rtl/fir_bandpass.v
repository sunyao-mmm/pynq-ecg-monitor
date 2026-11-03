`timescale 1ns / 1ps
`default_nettype none
// fir_bandpass.v : 65-tap 5-40 Hz bandpass FIR, Q15, symmetric fold, one serial multiplier.
// y = sat16(acc>>15); the 32-sample group delay is removed by ecg_detect_top.
module fir_bandpass #(
    parameter integer N       = 65,          // taps, odd, symmetric
    parameter integer DATA_W  = 16,
    parameter integer COEF_W  = 16,          // Q15
    parameter integer ACC_W   = 40
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     ce,          // 1 clock pulse per input sample
    input  wire signed [DATA_W-1:0] x,
    output reg  signed [DATA_W-1:0] y,
    output reg                      y_valid      // 1 clock pulse when y is a real output
);

    localparam integer HALF = (N + 1) / 2;       // 33 folded MACs
    localparam integer MW   = 6;                 // MAC counter width

    integer k;

    reg  signed [DATA_W-1:0] dl [0:N-1];         // sample delay line, dl[0] = newest
    reg  signed [ACC_W-1:0]  acc;
    reg  [MW-1:0]            mac;
    reg                      busy;
    reg  [15:0]              nsmp;               // input samples seen so far

    wire signed [DATA_W:0]          pair = dl[mac] + dl[N-1-mac];
    wire signed [COEF_W+DATA_W-1:0] prod = coef(mac) * pair;

    // ---------------- coefficient ROM (symmetric, Q15) ----------------
    function signed [COEF_W-1:0] coef(input integer j);
        case (j)
         0: coef = 16'sd38 ;
         1: coef = 16'sd12 ;
         2: coef = -16'sd11 ;
         3: coef = -16'sd10 ;
         4: coef = 16'sd21 ;
         5: coef = 16'sd60 ;
         6: coef = 16'sd61 ;
         7: coef = 16'sd0 ;
         8: coef = -16'sd90 ;
         9: coef = -16'sd130 ;
        10: coef = -16'sd67 ;
        11: coef = 16'sd46 ;
        12: coef = 16'sd69 ;
        13: coef = -16'sd97 ;
        14: coef = -16'sd380 ;
        15: coef = -16'sd555 ;
        16: coef = -16'sd448 ;
        17: coef = -16'sd148 ;
        18: coef = 16'sd7 ;
        19: coef = -16'sd279 ;
        20: coef = -16'sd921 ;
        21: coef = -16'sd1421 ;
        22: coef = -16'sd1277 ;
        23: coef = -16'sd517 ;
        24: coef = 16'sd156 ;
        25: coef = -16'sd115 ;
        26: coef = -16'sd1497 ;
        27: coef = -16'sd3036 ;
        28: coef = -16'sd3151 ;
        29: coef = -16'sd827 ;
        30: coef = 16'sd3392 ;
        31: coef = 16'sd7483 ;
        32: coef = 16'sd9175 ;
        default: coef = 16'sd0;
    endcase
    endfunction

    // ---------------- saturating >>15 ----------------
    function signed [DATA_W-1:0] sat16(input signed [ACC_W-1:0] v);
        begin
            if (v > 40'sd32767)       sat16 = 16'sd32767;
            else if (v < -40'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[DATA_W-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < N; k = k + 1) dl[k] <= {DATA_W{1'b0}};
            acc     <= {ACC_W{1'b0}};
            mac     <= {MW{1'b0}};
            busy    <= 1'b0;
            nsmp    <= 16'd0;
            y       <= {DATA_W{1'b0}};
            y_valid <= 1'b0;
        end
        else begin
            y_valid <= 1'b0;
            if (ce) begin
                // shift the new sample in, then sweep all 33 folded taps
                // (tap 0 is accumulated in the cycle right after this edge,
                //  when the delay line already holds the new sample)
                for (k = N-1; k > 0; k = k - 1) dl[k] <= dl[k-1];
                dl[0] <= x;
                acc   <= {ACC_W{1'b0}};
                mac   <= {MW{1'b0}};
                busy  <= 1'b1;
                if (nsmp < N) nsmp <= nsmp + 16'd1;
            end
            else if (busy) begin
                if (mac == HALF-1) begin
                    busy    <= 1'b0;
                    y       <= sat16((acc + prod) >>> 15);   // Q15 -> integer, saturate
                    y_valid <= (nsmp >= N);      // first N-1 outputs are the start-up transient
                end
                else begin
                    acc <= acc + prod;
                    mac <= mac + {{(MW-1){1'b0}}, 1'b1};
                end
            end
        end
    end

endmodule
`default_nettype wire
