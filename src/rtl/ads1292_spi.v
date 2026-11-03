`timescale 1ns / 1ps
`default_nettype none
// ads1292_spi.v : ADS1292(R) SPI master -> 250 Hz, 16-bit sample stream.
//
//   * SPI mode 1 (CPOL=0, CPHA=1), MSB first, SCLK ~1 MHz.  At <= 1 MHz a byte
//     takes 8 us, which already covers the chip's 4*tCLK (~7.8 us) decode time,
//     so no extra delay is needed between bytes.
//   * Puts the chip up in this order (values from the module's own STM32 driver):
//       SDATAC, RESET, wait, SDATAC, WREG(CONFIG1..GPIO, 11 bytes),
//       RREG(ID), RDATAC, START
//   * After that, every falling edge of DRDY clocks out the 9-byte frame
//     (3 status + 3 ch1 + 3 ch2) and pushes channel-1's top 16 bits out as one
//     sample, in step with the 250 Hz chain (notch -> FIR -> CLT).
//
//   * SELF CHECK: while the chip is still in SDATAC mode (registers may only be
//     touched in SDATAC - doing it in RDATAC makes the command be ignored and
//     would fake a "dead chip"), the ID register is read back with RREG, and
//     then RDATAC + START are issued.  The result is reported through the
//     normal sample stream as three "diagnostic samples" marked with
//     0xA5/0xA6/0xA7 in the high byte:
//         0xA5xx  chip ID      (0x53 = ADS1292, 0x73 = ADS1292R,
//                               0x5A = DOUT/DIN shorted -> loopback test ok,
//                               anything else = the chip did not answer)
//         0xA6xx  frames read so far (low 8 bits of the frame counter)
//         0xA7xx  first byte of the last frame (normally starts with 0xC0)
//     ecg_core swallows these three samples (they are not ECG), so they never
//     reach the filter, and parks the three bytes in a register instead.  The
//     batch is repeated DIAG_BATCHES times, DIAG_GAP clocks apart, so a slow
//     host still catches one.  No extra ports are needed.
//
module ads1292_spi #(
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer SCLK_HZ    = 1_000_000,
    parameter integer RESET_WAIT = 100_000_000,   // ~1 s, chip needs it after RESET
    parameter integer GAP_CYC    = 500,           // CS-high gap between transactions
    parameter integer DIAG_BATCHES = 3,           // diagnostic batches (0 = disable)
    parameter integer DIAG_GAP     = 100_000_000, // clocks between batches (~1 s)
    parameter integer DIAG_WARM    = 0,           // neutral samples before the markers
                                                  // (ecg_core swallows the markers now,
                                                  //  so the FIR no longer needs flushing)
    parameter integer DIAG_SPACE   = 80           // clocks between injected samples
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_RESET rst_n, FREQ_HZ 20000000, PHASE 0.0" *)
    input  wire              clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire              rst_n,
    input  wire              start,          // pulse: run the init sequence
    output reg               sclk,
    output reg               mosi,           // -> DIN
    input  wire              miso,           // <- DOUT
    output reg               cs_n,
    input  wire              drdy_n,         // <- DRDY (1->0 = new sample)
    output reg signed [15:0] sample,         // channel 1, top 16 of the 24 bits
    output reg               sample_valid,   // one clk pulse per sample
    output reg               init_done
);

    localparam integer DIV = CLK_HZ / (3*SCLK_HZ);   // clocks per SCLK sub-phase

    // ---------------- register values (the module's driver, DR changed to 250 SPS) ----------------
    //
    // CH1SET value : 0x20 = channel 1 on, gain 2, normal electrode input.
    //   Gain field [6:4] is coded 0=gain6, 1=gain1, 2=gain2, 3=gain3, 4=gain4,
    //   5=gain8, 6=gain12.  Gain 2 is what the vendor's own demo uses and it keeps
    //   the input range at +/-1.21 V (an electrode DC offset will not saturate it).
    //   If the live ECG ever looks too small after the 24->16 bit truncation,
    //   gain 6 (0x00) or gain 12 (0x60) can be tried - but watch for saturation.
    localparam [7:0] CH1SET_VALUE = 8'h20;

    // RESP1/RESP2 : this board carries a plain ADS1292 (no "R", no respiration).
    //   TI datasheet SBAS502, RESP1 section: "For the ADS1291 and ADS1292 devices,
    //   02h must be written to the RESP1 register".  RESP2 bit2 (RESP_FREQ) must be
    //   written with '1' for the same parts.  Writing the ADS1292R respiration
    //   defaults here (0xF6 / 0x03) makes the data come out wrong on a non-R part.
    function [7:0] regval(input integer i);
        case (i)
            0:  regval = 8'h01;   // CONFIG1 : DR=001 -> 250 SPS
            1:  regval = 8'hE1;   // CONFIG2 : bit7=1, refbuf on, loff comp on
            2:  regval = 8'h10;   // LOFF
            3:  regval = CH1SET_VALUE;   // CH1SET : channel 1, gain 2
            4:  regval = 8'h00;   // CH2SET : channel 2, gain 6
            5:  regval = 8'hEC;   // RLD_SENS  : right-leg drive on
            6:  regval = 8'h0C;   // LOFF_SENS : lead-off detect on ch2
            7:  regval = 8'h00;   // LOFF_STAT
            8:  regval = 8'h02;   // RESP1 : non-R part -> respiration off (required)
            9:  regval = 8'h07;   // RESP2 : non-R part -> RESP_FREQ=1 (required)
            10: regval = 8'h0C;   // GPIO
            default: regval = 8'h00;
        endcase
    endfunction

    // ---------------- bit engine: send tx_data, capture rx_sr (MSB first) ----------------
    reg  [7:0]  tx_data, tx_sr, rx_sr;
    reg         tx_req, tx_ack, active;
    reg  [2:0]  bn, sub;
    reg  [31:0] dc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk <= 1'b0; mosi <= 1'b0; tx_ack <= 1'b0; active <= 1'b0;
            bn <= 3'd0; sub <= 3'd0; dc <= 32'd0; tx_sr <= 8'h00; rx_sr <= 8'h00;
        end
        else begin
            tx_ack <= 1'b0;
            if (!active) begin
                sclk <= 1'b0;
                if (tx_req) begin
                    tx_sr <= tx_data; rx_sr <= 8'h00;
                    bn <= 3'd0; sub <= 3'd0; dc <= 32'd0; active <= 1'b1;
                end
            end
            else if (dc == DIV-1) begin
                dc <= 32'd0;
                case (sub)
                3'd0: begin sclk <= 1'b1; mosi <= tx_sr[7]; tx_sr <= {tx_sr[6:0], 1'b0}; sub <= 3'd1; end
                3'd1: begin sclk <= 1'b0; rx_sr <= {rx_sr[6:0], miso};                  sub <= 3'd2; end
                default: begin
                    if (bn == 3'd7) begin active <= 1'b0; tx_ack <= 1'b1; end
                    else            begin bn <= bn + 3'd1; sub <= 3'd0; end
                end
                endcase
            end
            else dc <= dc + 32'd1;
        end
    end

    // ---------------- byte / command sequencer ----------------
    localparam [3:0] S_IDLE=4'd0, S_CMD=4'd1, S_WAIT=4'd2, S_WRH=4'd3,
                     S_WRC=4'd4, S_WRD=4'd5, S_READY=4'd6, S_READ=4'd7,
                     S_RRH=4'd8, S_RRL=4'd9, S_RRD=4'd10, S_DIAG=4'd11;

    localparam [7:0] C_SDATAC = 8'h11,
                     C_RESET  = 8'h06,
                     C_RDATAC = 8'h10,
                     C_START  = 8'h08,
                     C_WREG1  = 8'h41,   // WREG | CONFIG1
                     C_RREG0  = 8'h20,   // RREG | ID (read the ID register back)
                     C_RRDDMY = 8'h5A;   // byte clocked in while the ID comes back.
                                         // Not a valid command, so a real chip
                                         // ignores it - but if DOUT and DIN are
                                         // shorted together the DUT sees 0x5A in
                                         // its own rx_sr, which proves the whole
                                         // FPGA-side SPI path works.

    function [7:0] cmdval(input [3:0] s);
        case (s)
            4'd0:    cmdval = C_SDATAC;
            4'd1:    cmdval = C_RESET;
            4'd2:    cmdval = C_SDATAC;
            4'd3:    cmdval = C_RDATAC;
            default: cmdval = C_START;
        endcase
    endfunction

    reg  [3:0]  state;
    reg  [3:0]  step, bcnt;
    reg  [4:0]  ridx;
    reg  [31:0] wcnt, gap;
    reg  [7:0]  rxbuf [0:8];
    reg         pend, drdy_d;

    // ---------------- self check / diagnostics ----------------
    reg  [7:0]  chip_id;        // ID register read back after the init sequence
    reg  [31:0] frame_cnt;      // number of 9-byte frames read since reset
    reg  [7:0]  last_status;    // first byte of the last frame (normally 0xC0)
    // 诊断批次（A5/A6/A7 三个字，每 DIAG_GAP 个时钟送一批）
    reg  [7:0]  diag_i;
    reg  [1:0]  diag_batch;
    reg  [31:0] batch_gap;
    reg  [7:0]  emit_gap;
    wire drdy_fall = drdy_d & ~drdy_n;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; step <= 4'd0; ridx <= 5'd0; bcnt <= 4'd0; wcnt <= 32'd0; gap <= 32'd0;
            cs_n <= 1'b1; tx_req <= 1'b0; pend <= 1'b0; init_done <= 1'b0; drdy_d <= 1'b1;
            sample <= 16'sd0; sample_valid <= 1'b0;
            chip_id <= 8'h00; frame_cnt <= 32'd0; last_status <= 8'h00;
            diag_i <= 8'd0; diag_batch <= 2'd0; batch_gap <= 32'd0; emit_gap <= 8'd0;
            for (k = 0; k < 9; k = k + 1) rxbuf[k] <= 8'h00;
        end
        else begin
            tx_req <= 1'b0;
            sample_valid <= 1'b0;
            drdy_d <= drdy_n;
            if (gap != 32'd0) gap <= gap - 32'd1;

            case (state)
            S_IDLE: begin
                cs_n <= 1'b1; init_done <= 1'b0;
                if (start) begin step <= 4'd0; state <= S_CMD; end
            end

            S_CMD: begin
                if (!pend) begin
                    if (gap == 32'd0) begin
                        cs_n <= 1'b0; tx_data <= cmdval(step); tx_req <= 1'b1; pend <= 1'b1;
                    end
                end
                else if (tx_ack) begin
                    pend <= 1'b0; cs_n <= 1'b1; gap <= GAP_CYC;
                    case (step)
                    4'd0: begin step <= 4'd1; end
                    4'd1: begin step <= 4'd2; state <= S_WAIT; end
                    4'd2: begin ridx <= 5'd0; state <= S_WRH; end
                    4'd3: begin step <= 4'd4; end              // RDATAC just went out
                    default: begin                             // START just went out
                        init_done <= 1'b1;
                        diag_i    <= 8'd0;
                        emit_gap  <= 8'd0;
                        if (DIAG_BATCHES == 0) state <= S_READY;
                        else                   state <= S_DIAG; // first diagnostic batch
                    end
                    endcase
                end
            end

            // ---- RREG | ID : send 0x20, then 0x00 (read 1 register), then clock the byte
            // in.  This runs while the chip is still in SDATAC mode (i.e. right
            // after the WREG block, before RDATAC), which is the only state in
            // which the ADS1292 accepts register commands.
            S_RRH: begin
                if (!pend) begin
                    if (gap == 32'd0) begin
                        cs_n <= 1'b0; tx_data <= C_RREG0; tx_req <= 1'b1; pend <= 1'b1;
                    end
                end
                else if (tx_ack) begin
                    tx_data <= 8'h00; tx_req <= 1'b1; state <= S_RRL;   // keep CS low
                end
            end

            S_RRL: begin
                if (tx_ack) begin
                    tx_data <= C_RRDDMY; tx_req <= 1'b1; state <= S_RRD;  // ID comes back during this byte
                end
            end

            S_RRD: begin
                if (tx_ack) begin
                    chip_id      <= rx_sr;
                    pend         <= 1'b0;
                    cs_n         <= 1'b1;
                    gap          <= GAP_CYC;
                    state        <= S_CMD;      // step is still 3 -> RDATAC goes out next
                end
            end

            // ---- diagnostic batch: DIAG_WARM neutral samples, then A5/A6/A7 markers
            S_DIAG: begin
                if (emit_gap != 8'd0) begin
                    emit_gap <= emit_gap - 8'd1;
                end
                else if (diag_i < DIAG_WARM) begin
                    sample       <= 16'sd0;
                    sample_valid <= 1'b1;
                    emit_gap     <= DIAG_SPACE[7:0];
                    diag_i       <= diag_i + 8'd1;
                end
                else if (diag_i == DIAG_WARM) begin
                    sample       <= {8'hA5, chip_id};
                    sample_valid <= 1'b1;
                    emit_gap     <= DIAG_SPACE[7:0];
                    diag_i       <= diag_i + 8'd1;
                end
                else if (diag_i == DIAG_WARM + 1) begin
                    sample       <= {8'hA6, frame_cnt[7:0]};
                    sample_valid <= 1'b1;
                    emit_gap     <= DIAG_SPACE[7:0];
                    diag_i       <= diag_i + 8'd1;
                end
                else begin
                    // 2026-10-19: DRDY 停顿计数已删除，诊断批次回到 A5/A6/A7 三个字
                    sample       <= {8'hA7, last_status};
                    sample_valid <= 1'b1;
                    diag_i       <= 8'd0;
                    if (diag_batch + 1'b1 >= DIAG_BATCHES) begin
                        batch_gap <= 32'd0;                             // no more batches
                    end
                    else begin
                        diag_batch <= diag_batch + 1'b1;
                        batch_gap  <= DIAG_GAP;
                    end
                    state <= S_READY;
                end
            end

            S_WAIT: begin
                if (wcnt == RESET_WAIT-1) begin wcnt <= 32'd0; state <= S_CMD; end
                else wcnt <= wcnt + 32'd1;
            end

            S_WRH: begin
                if (!pend) begin
                    if (gap == 32'd0) begin
                        cs_n <= 1'b0; tx_data <= C_WREG1; tx_req <= 1'b1; pend <= 1'b1;
                    end
                end
                else if (tx_ack) begin
                    tx_data <= 8'd10; tx_req <= 1'b1; state <= S_WRC;   // keep CS low
                end
            end

            S_WRC: begin
                if (tx_ack) begin
                    tx_data <= regval(0); ridx <= 5'd1; tx_req <= 1'b1; state <= S_WRD;
                end
            end

            S_WRD: begin
                if (tx_ack) begin
                    if (ridx == 5'd11) begin
                        // registers are written; read the ID back while we are
                        // still in SDATAC, then let S_CMD send RDATAC (step 3).
                        pend <= 1'b0; cs_n <= 1'b1; gap <= GAP_CYC; step <= 4'd3; state <= S_RRH;
                    end
                    else begin
                        tx_data <= regval(ridx); ridx <= ridx + 5'd1; tx_req <= 1'b1;
                    end
                end
            end

            S_READY: begin
                init_done <= 1'b1;
                if (batch_gap != 32'd0) begin
                    // Between two diagnostic batches we keep serving DRDY so the
                    // frame counter keeps climbing (that is what the 0xA6 marker
                    // reports).  A frame read pauses the countdown for ~200 clocks,
                    // which is nothing against DIAG_GAP.
                    batch_gap <= batch_gap - 32'd1;
                    if (batch_gap == 32'd1) begin        // next diagnostic batch starts now
                        diag_i   <= 8'd0;
                        emit_gap <= 8'd0;
                        state    <= S_DIAG;
                    end
                    else if (drdy_fall && gap == 32'd0) begin
                        cs_n <= 1'b0; bcnt <= 4'd0; tx_data <= 8'h00; tx_req <= 1'b1;
                        pend <= 1'b1; state <= S_READ;
                    end
                end
                else if (drdy_fall && gap == 32'd0) begin
                    cs_n <= 1'b0; bcnt <= 4'd0; tx_data <= 8'h00; tx_req <= 1'b1;
                    pend <= 1'b1; state <= S_READ;
                end
            end

            S_READ: begin
                if (tx_ack) begin
                    rxbuf[bcnt] <= rx_sr;
                    if (bcnt == 4'd8) begin
                        pend <= 1'b0; cs_n <= 1'b1; gap <= GAP_CYC;
                        // 24-bit frame: b0..b2 = status, b3..b5 = channel 1, b6..b8 = channel 2.
                        // The ECG on this module is on CHANNEL 2: the vendor's own STM32
                        // demo plots p_Temp[1] (= channel 2), and it is channel 2 that the
                        // RLD driver and the lead-off detection are wired to
                        // (RLD_SENS = 0xEC, LOFF_SENS = 0x0C).  Reading channel 1 gives
                        // only the noise of an unconnected input pair.
                        sample <= {rxbuf[6], rxbuf[7]};   // top 16 bits of channel 2
                        sample_valid <= 1'b1;
                        last_status <= rxbuf[0];          // frame's status byte (should start 0xC0)
                        frame_cnt   <= frame_cnt + 32'd1;
                        state <= S_READY;
                    end
                    else begin
                        bcnt <= bcnt + 4'd1; tx_data <= 8'h00; tx_req <= 1'b1;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire






