`timescale 1ns / 1ps
`default_nettype none
// tb_ads1292_spi.v -- self-checking testbench for ads1292_spi.
//
//   Contains a behavioural "fake ADS1292": it decodes the command bytes,
//   answers the 9-byte read frame, answers RREG|ID with ID_VALUE and pulses
//   DRDY at a fixed rate.  Channel 1 walks through six known 24-bit values
//   (incl. sign and dropped-low-byte cases) so the DUT's 16-bit samples can be
//   checked exactly.
//
//   The sample stream is a mix of
//     * diagnostic markers (high byte 0xA5 / 0xA6 / 0xA7), DIAG_BATCHES batches
//       spread DIAG_GAP clocks apart, and
//     * the real channel-1 frames read on every DRDY,
//   so the checker classifies every sample instead of assuming a fixed order.
module tb_ads1292_spi;

    reg clk = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    reg                rst_n, start;
    wire               sclk, mosi, cs_n, miso, drdy_n;
    wire signed [15:0] sample;
    wire               sample_valid, init_done;
    wire [7:0]         m_nwreg, m_wreg0, m_wreg1;
    wire [7:0]         m_ch1set, m_resp1, m_resp2;

    integer errs, nchk, chks, tmo;
    integer nsv;                            // total sample_valid pulses seen
    integer nbatch;                         // completed diagnostic batches
    integer i2, found, prev_idx;            // helpers for the frame-value check
    reg [7:0] b5, b6, b7;                   // markers of the batch in progress
    reg signed [15:0] exp_s [0:5];

    // ---- log every byte the DUT puts on DIN, so the command ORDER can be
    //      checked (register access must happen before RDATAC) ----
    reg [7:0] txlog [0:31];
    integer   tx_n;
    always @(posedge clk) begin
        if (rst_n && dut.tx_req && tx_n < 32) begin
            txlog[tx_n] = dut.tx_data;
            tx_n = tx_n + 1;
        end
    end


    localparam integer DIAG_WARM    = 0;    // must match the DUT (the FIR no longer
                                            // needs flushing - ecg_core swallows
                                            // the markers - so 0 is the default)
    localparam integer DIAG_SPACE   = 80;
    localparam integer DIAG_BATCHES = 2;
    localparam integer DIAG_GAP     = 60000;   // > 1 DRDY period so frames show up in batch 2

    ads1292_spi #(
        .CLK_HZ(100_000_000), .SCLK_HZ(1_000_000),
        .RESET_WAIT(1000), .GAP_CYC(50),
        .DIAG_BATCHES(DIAG_BATCHES), .DIAG_GAP(DIAG_GAP),
        .DIAG_WARM(DIAG_WARM), .DIAG_SPACE(DIAG_SPACE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n), .drdy_n(drdy_n),
        .sample(sample), .sample_valid(sample_valid), .init_done(init_done)
    );

    ads1292_model #(.DRDY_DIV(20000)) model (
        .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
        .miso(miso), .drdy_n(drdy_n),
        .n_wreg(m_nwreg), .wreg0(m_wreg0), .wreg1(m_wreg1),
        .ch1set(m_ch1set), .resp1(m_resp1), .resp2(m_resp2)
    );

    // Sample stream: DIAG_WARM neutral samples followed by the three markers of a
    // batch; the real channel-1 frames are interleaved in between the batches.
    always @(posedge clk) begin
        if (rst_n && sample_valid) begin
            nsv = nsv + 1;
            case (sample[15:8])
            8'hA5: b5 = sample[7:0];
            8'hA6: b6 = sample[7:0];
            8'hA7: begin
                b7 = sample[7:0];
                nbatch = nbatch + 1;
                chks = chks + 1;
                if (b5 !== 8'h73) begin
                    errs = errs + 1;
                    $display("  FAIL batch%0d chip ID = 0x%02x (expect 0x73)", nbatch, b5);
                end
                else if (nbatch == 1) begin
                    $display("  ok   batch1: chip ID read back = 0x73 (ADS1292R), frames so far = %0d", b6);
                end
                else if (b6 == 8'd0) begin
                    errs = errs + 1;
                    $display("  FAIL batch%0d frame counter = 0 (frames should be flowing)", nbatch);
                end
                else begin
                    $display("  ok   batch%0d: chip ID 0x73, frames so far = %0d, status = 0x%02x",
                             nbatch, b6, b7);
                    if (b7 !== 8'hC0) begin
                        errs = errs + 1;
                        $display("  FAIL batch%0d status byte = 0x%02x (expect 0xC0)", nbatch, b7);
                    end
                end
            end
            default: begin
                // a real channel-1 frame
                if (nchk < 6) begin
                    chks = chks + 1;
                    found = -1;
                    for (i2 = 0; i2 < 6; i2 = i2 + 1)
                        if (sample === exp_s[i2]) found = i2;
                    if (found < 0) begin
                        errs = errs + 1;
                        $display("  FAIL frame[%0d] = %0d   (not one of the expected values)", nchk, sample);
                    end
                    else if (nchk > 0 && found !== ((prev_idx + 1) % 6)) begin
                        errs = errs + 1;
                        $display("  FAIL frame[%0d] = %0d   (frame order broken, prev was #%0d)",
                                 nchk, sample, prev_idx);
                    end else begin
                        $display("  ok   frame[%0d] = %0d  (channel-1 frame #%0d)", nchk, sample, found);
                    end
                    prev_idx = found;
                    nchk = nchk + 1;
                end
            end
            endcase
        end
    end

    initial begin
        exp_s[0] =  16'sd1;
        exp_s[1] =  16'sd32767;
        exp_s[2] =  16'sh8000;      // -32768
        exp_s[3] = -16'sd256;
        exp_s[4] =  16'sd4660;
        exp_s[5] = -16'sd21555;
    end

    initial begin
        rst_n = 1'b0; start = 1'b0;
        errs = 0; nchk = 0; chks = 0; nsv = 0; nbatch = 0; prev_idx = 0;
        b5 = 8'h00; b6 = 8'h00; b7 = 8'h00;
        tx_n = 0;
        $display("=========== ads1292_spi : SPI master bring-up ===========");
        $display("*** TB BUILD ADS1292-2 ***");

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        tmo = 0;
        while (init_done !== 1'b1 && tmo < 2_000_000) begin
            @(posedge clk);
            tmo = tmo + 1;
        end
        if (init_done === 1'b1) $display("  ok   init_done raised");
        else begin $display("  FAIL init sequence did not finish"); errs = errs + 1; end
        chks = chks + 1;

        repeat (2_000_000) @(posedge clk);

        chks = chks + 1;
        if (m_nwreg == 8'd11 && m_wreg0 == 8'h01 && m_wreg1 == 8'hE1)
            $display("  ok   WREG: 11 bytes, CONFIG1=0x01 (250 SPS), CONFIG2=0xE1");
        else begin
            errs = errs + 1;
            $display("  FAIL WREG: n=%0d CONFIG1=0x%02x CONFIG2=0x%02x (expect 11/01/E1)",
                     m_nwreg, m_wreg0, m_wreg1);
        end

        // The board carries a plain ADS1292 (no "R"): the datasheet demands
        // RESP1 = 0x02 and RESP2 bit2 = 1, otherwise the samples come out wrong.
        chks = chks + 1;
        if (m_resp1 == 8'h02 && m_resp2 == 8'h07 && m_ch1set == 8'h20)
            $display("  ok   non-R config: CH1SET=0x20 (gain 2), RESP1=0x02, RESP2=0x07");
        else begin
            errs = errs + 1;
            $display("  FAIL non-R config: CH1SET=0x%02x RESP1=0x%02x RESP2=0x%02x (expect 20/02/07)",
                     m_ch1set, m_resp1, m_resp2);
        end

        chks = chks + 1;
        if (nchk == 6) $display("  ok   six samples read");
        else begin errs = errs + 1; $display("  FAIL only %0d samples read", nchk); end

        chks = chks + 1;
        if (nbatch >= DIAG_BATCHES)
            $display("  ok   %0d diagnostic batches emitted", nbatch);
        else begin
            errs = errs + 1;
            $display("  FAIL only %0d of %0d diagnostic batches emitted", nbatch, DIAG_BATCHES);
        end

        // Command order: SDATAC, RESET, SDATAC, WREG|CONFIG1 + 11 data bytes,
        // RREG|ID + count + dummy(0x5A), RDATAC, START.  The register read HAS
        // to sit before RDATAC - the ADS1292 only decodes register commands in
        // SDATAC mode.
        chks = chks + 1;
        if (tx_n >= 21 &&
            txlog[0] === 8'h11 && txlog[1] === 8'h06 && txlog[2] === 8'h11 &&
            txlog[3] === 8'h41 && txlog[4] === 8'h0A &&
            txlog[16] === 8'h20 && txlog[17] === 8'h00 && txlog[18] === 8'h5A &&
            txlog[19] === 8'h10 && txlog[20] === 8'h08)
            $display("  ok   command order: ... WREG, RREG|ID(0x20 00 5A), RDATAC(0x10), START(0x08)");
        else begin
            errs = errs + 1;
            $display("  FAIL command order (=%0d bytes): %02x %02x %02x %02x %02x <%02x %02x %02x> %02x %02x",
                     tx_n, txlog[0], txlog[1], txlog[2], txlog[3], txlog[4],
                     txlog[16], txlog[17], txlog[18], txlog[19], txlog[20]);
            $display("       expect 11 06 11 41 0A <20 00 5A> 10 08");
        end

        $display("-------------------------------------------------------");
        $display("checks = %0d   errors = %0d", chks, errs);
        if (errs == 0) $display("  RESULT: PASS");
        else           $display("  RESULT: FAIL");
        $display("=======================================================");
        $finish;
    end

endmodule


// ---------------------------------------------------------------------------
// behavioural ADS1292: mode-1 slave, answers the 9-byte frame, pulses DRDY
// ---------------------------------------------------------------------------
module ads1292_model #(
    parameter integer DRDY_DIV = 20000,
    parameter [7:0]   ID_VALUE = 8'h73      // value returned by RREG|ID
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sclk,
    input  wire       mosi,
    input  wire       cs_n,
    output wire       miso,
    output reg        drdy_n,
    output reg [7:0]  n_wreg,
    output reg [7:0]  wreg0,
    output reg [7:0]  wreg1,
    output reg [7:0]  ch1set,      // WREG data byte 3 (CH1SET)
    output reg [7:0]  resp1,       // WREG data byte 8 (RESP1)
    output reg [7:0]  resp2        // WREG data byte 9 (RESP2)
);

    // ---- what channel 1 sends, cycled through six known 24-bit values ----
    function [23:0] ch1_of(input [2:0] i);
        case (i)
            3'd0:    ch1_of = 24'h000100;   // -> 1
            3'd1:    ch1_of = 24'h7FFF00;   // -> 32767
            3'd2:    ch1_of = 24'h800000;   // -> -32768
            3'd3:    ch1_of = 24'hFF0000;   // -> -256
            3'd4:    ch1_of = 24'h1234FF;   // -> 4660  (low byte dropped)
            default: ch1_of = 24'hABCDEF;   // -> -21555
        endcase
    endfunction

    reg [23:0] ch1_cur;
    reg [2:0]  sidx6;
    reg        running;
    reg [31:0] dcnt;

    reg [71:0] frame_sh;
    reg [6:0]  bitn;
    reg        dout_r;

    reg [7:0]  rx_sr;
    reg [2:0]  bitn2;
    reg [7:0]  rxb [0:15];
    reg [4:0]  rx_cnt;

    reg [7:0]  op;

    reg        rreg_mode;                  // the current transaction is a register read

    assign miso = dout_r;

    // ---- DOUT: present frame_sh[71-bitn] at each rising edge (mode 1) ----
    // The DUT reads CHANNEL 2 (bytes b6..b8), so the known test pattern is placed
    // in the third byte group; channel 1 (b3..b5) is left at zero, exactly like
    // the real module where only channel 2 carries the ECG.
    always @(negedge cs_n) begin
        frame_sh <= {24'hC00000, 24'h000000, ch1_cur};
        bitn     <= 7'd0;
        rreg_mode <= 1'b0;
    end

    always @(posedge sclk or negedge rst_n) begin
        if (!rst_n) begin dout_r <= 1'b0; bitn <= 7'd0; end
        else if (!cs_n) begin
            // for a register read the third byte carries the register value
            dout_r <= (rreg_mode && bitn >= 7'd16 && bitn < 7'd24)
                      ? ID_VALUE[3'd7 - bitn[2:0]]
                      : frame_sh[71 - bitn];
            bitn   <= bitn + 7'd1;
        end
    end

    // ---- DIN: capture at each falling edge, one byte at a time ----
    always @(negedge sclk or negedge rst_n) begin
        if (!rst_n) begin rx_sr <= 8'h00; bitn2 <= 3'd0; rx_cnt <= 5'd0; end
        else if (!cs_n) begin
            rx_sr <= {rx_sr[6:0], mosi};
            if (bitn2 == 3'd7) begin
                bitn2 <= 3'd0;
                rxb[rx_cnt] <= {rx_sr[6:0], mosi};
                rx_cnt <= rx_cnt + 5'd1;
                if (rx_cnt == 5'd0)
                    rreg_mode <= ({rx_sr[6:0], mosi} == 8'h20);   // RREG | ID
            end else bitn2 <= bitn2 + 3'd1;
        end
    end

    // ---- decode the opcode when CS goes back high ----
    always @(posedge cs_n or negedge rst_n) begin
        if (!rst_n) begin
            n_wreg <= 8'd0; wreg0 <= 8'h00; wreg1 <= 8'h00;
            ch1set <= 8'h00; resp1 <= 8'h00; resp2 <= 8'h00;
        end
        else begin
            op = rxb[0];
            case (op)
                8'h08:   running <= 1'b1;                                   // START
                8'h41:   begin
                             n_wreg <= rxb[1] + 8'd1;                        // length-1
                             wreg0  <= rxb[2];                               // CONFIG1
                             wreg1  <= rxb[3];                               // CONFIG2
                             ch1set <= rxb[5];                               // CH1SET
                             resp1  <= rxb[10];                              // RESP1
                             resp2  <= rxb[11];                              // RESP2
                         end
                default: ;                                                  // SDATAC/RESET/RDATAC/read
            endcase
            rx_cnt <= 5'd0; bitn2 <= 3'd0;
        end
    end

    // ---- DRDY: one short low pulse every DRDY_DIV clocks once running ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drdy_n <= 1'b1; running <= 1'b0; dcnt <= 32'd0; sidx6 <= 3'd0; ch1_cur <= 24'h000100;
        end
        else if (running) begin
            if (dcnt == DRDY_DIV-1) begin
                dcnt    <= 32'd0;
                drdy_n  <= 1'b0;
                ch1_cur <= ch1_of(sidx6);
                sidx6   <= (sidx6 == 3'd5) ? 3'd0 : sidx6 + 3'd1;
            end
            else begin
                if (dcnt == 32'd20) drdy_n <= 1'b1;
                dcnt <= dcnt + 32'd1;
            end
        end
    end

endmodule
`default_nettype wire



