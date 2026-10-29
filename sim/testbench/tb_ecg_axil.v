`timescale 1ns / 1ps
`default_nettype none
//==========================================================================
// tb_ecg_axil.v -- AXI4-Lite register test                       (AXIL-1)
//
//   Emulates what the ARM (PS) does: AXI4-Lite writes and reads.  It checks
//   the ID register, a scratch loop-back, the CTRL/STATUS handshake, and that
//   every status register reads back the value that was driven into it.
//
//   The AXI stimulus is driven on the FALLING edge on purpose - driving it on
//   the rising edge races with the DUT sampling on that edge (the bug we hit
//   in the heart-rate testbench).
//
//   ASCII only on purpose.
//==========================================================================
module tb_ecg_axil;

    localparam integer AW = 6;
    localparam integer DW = 32;

    reg clk = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    reg rstn;

    // ---------------- AXI4-Lite master (the "ARM") ----------------
    reg  [AW-1:0] awaddr;   reg awvalid;  wire awready;
    reg  [DW-1:0] wdata;    reg [3:0] wstrb;  reg wvalid;  wire wready;
    wire [1:0]    bresp;    wire bvalid;  reg bready;
    reg  [AW-1:0] araddr;   reg arvalid;  wire arready;
    wire [DW-1:0] rdata;    wire [1:0] rresp; wire rvalid; reg rready;

    // ---------------- pretend ECG status (in 2-2 these come from ecg_core) ----
    reg [31:0] st_clt_now, st_r_index, st_rr_samples, st_beat_count, st_rr_bad_cnt;
    reg [15:0] st_r_amp, st_bpm;
    reg        st_cap_done;
    wire       ctrl_run, ctrl_soft_rst, ctrl_src;
    wire [31:0] cap_len;
    wire [11:0] cap_rd_addr;
    wire [31:0] cap_rd_data;

    // behavioural stand-in for the capture BRAM (Block Memory Generator, port B)
    reg [31:0] bram [0:4095];
    reg [31:0] bram_dout;
    always @(posedge clk) bram_dout <= bram[cap_rd_addr];
    assign cap_rd_data = bram_dout;

    integer errs, checks;
    reg [31:0] rd;

    ecg_axil #(.C_S_AXI_DATA_WIDTH(32), .C_S_AXI_ADDR_WIDTH(6)) dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rstn),
        .S_AXI_AWADDR(awaddr), .S_AXI_AWPROT(3'b000), .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
        .S_AXI_WDATA(wdata), .S_AXI_WSTRB(wstrb), .S_AXI_WVALID(wvalid), .S_AXI_WREADY(wready),
        .S_AXI_BRESP(bresp), .S_AXI_BVALID(bvalid), .S_AXI_BREADY(bready),
        .S_AXI_ARADDR(araddr), .S_AXI_ARPROT(3'b000), .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
        .S_AXI_RDATA(rdata), .S_AXI_RRESP(rresp), .S_AXI_RVALID(rvalid), .S_AXI_RREADY(rready),
        .ctrl_run(ctrl_run), .ctrl_soft_rst(ctrl_soft_rst), .ctrl_src(ctrl_src), .cap_len(cap_len),
        .cap_rd_addr(cap_rd_addr), .cap_rd_data(cap_rd_data),
        .st_clt_now(st_clt_now), .st_r_index(st_r_index), .st_r_amp(st_r_amp),
        .st_bpm(st_bpm), .st_rr_samples(st_rr_samples), .st_beat_count(st_beat_count),
        .st_rr_bad_cnt(st_rr_bad_cnt), .st_cap_done(st_cap_done)
    );

    // ---------------- AXI4-Lite master tasks ----------------
    task axi_write(input [AW-1:0] a, input [DW-1:0] d);
    begin
        @(negedge clk);
        awaddr = a; awvalid = 1'b1; wdata = d; wstrb = 4'hF; wvalid = 1'b1; bready = 1'b0;
        @(posedge clk);
        while (!(awready && wready)) @(posedge clk);
        @(negedge clk);
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        @(negedge clk);
        bready = 1'b0;
    end
    endtask

    task axi_read(input [AW-1:0] a, output [DW-1:0] d);
    begin
        @(negedge clk);
        araddr = a; arvalid = 1'b1; rready = 1'b0;
        @(posedge clk);
        while (!arready) @(posedge clk);
        @(negedge clk);
        arvalid = 1'b0; rready = 1'b1;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(negedge clk);
        rready = 1'b0;
    end
    endtask

    task check(input [8*22-1:0] name, input [31:0] got, input [31:0] exp);
    begin
        checks = checks + 1;
        if (got === exp) $display("  ok   %0s = 0x%08x", name, got);
        else begin
            errs = errs + 1;
            $display("  FAIL %0s = 0x%08x   (expect 0x%08x)", name, got, exp);
        end
    end
    endtask

    initial begin
        rstn = 1'b0;
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        st_clt_now = 0; st_r_index = 0; st_r_amp = 0; st_bpm = 0;
        st_rr_samples = 0; st_beat_count = 0; st_rr_bad_cnt = 0; st_cap_done = 0;
        errs = 0; checks = 0; rd = 0;

        repeat (5) @(negedge clk);
        rstn = 1'b1;
        repeat (2) @(negedge clk);

        $display("====== ecg_axil : AXI4-Lite register test (the ARM would do this) ======");
        $display("*** TB BUILD AXIL-1 ***");

        axi_read(6'h2C, rd);                 check("ID (read only)", rd, 32'h0EC60001);

        axi_write(6'h28, 32'hA5A55A5A);
        axi_read (6'h28, rd);                check("SCRATCH  A5A55A5A", rd, 32'hA5A55A5A);
        axi_write(6'h28, 32'h12345678);
        axi_read (6'h28, rd);                check("SCRATCH  12345678", rd, 32'h12345678);

        axi_read (6'h04, rd);                check("STATUS before run", rd, 32'h00000000);
        axi_write(6'h00, 32'h00000001);
        axi_read (6'h04, rd);                check("STATUS run bit", {31'd0, rd[0]}, 32'd1);
        check("ctrl_run output", {31'd0, ctrl_run}, 32'd1);
        check("ctrl_src initial", {31'd0, ctrl_src}, 32'd0);

        axi_write(6'h00, 32'h00000005);
        check("ctrl_src set", {31'd0, ctrl_src}, 32'd1);
        axi_write(6'h00, 32'h00000001);
        check("ctrl_src clear", {31'd0, ctrl_src}, 32'd0);

        st_clt_now = 32'd15660; st_r_index = 32'd947; st_r_amp = 16'd1080;
        st_bpm = 16'd74; st_rr_samples = 32'd284; st_beat_count = 32'd4;
        st_rr_bad_cnt = 32'd1; st_cap_done = 1'b1;

        axi_read(6'h08, rd);                 check("CLT_NOW",    rd, 32'd15660);
        axi_read(6'h0C, rd);                 check("R_INDEX",    rd, 32'd947);
        axi_read(6'h10, rd);                 check("R_AMP",      rd, 32'd1080);
        axi_read(6'h14, rd);                 check("BPM",        rd, 32'd74);
        axi_read(6'h18, rd);                 check("RR_SAMPLES", rd, 32'd284);
        axi_read(6'h1C, rd);                 check("BEAT_COUNT", rd, 32'd4);
        axi_read(6'h20, rd);                 check("RR_BAD_CNT", rd, 32'd1);
        axi_read(6'h04, rd);
        check("STATUS cap_done bit", {31'd0, rd[1]}, 32'd1);
        check("STATUS beat hi word", {16'd0, rd[31:16]}, 32'd4);

        axi_read (6'h24, rd);                check("CAP_LEN default", rd, 32'd1024);
        axi_write(6'h24, 32'd512);
        axi_read (6'h24, rd);                check("CAP_LEN  after wr", rd, 32'd512);
        check("cap_len output", cap_len, 32'd512);

        axi_read (6'h3C, rd);                check("unused register", rd, 32'd0);

        axi_write(6'h00, 32'h00000000);
        axi_read (6'h04, rd);                check("STATUS run cleared", {31'd0, rd[0]}, 32'd0);

        // ---------------- capture buffer read path (round 2) ----------------
        // pretend the ECG core captured these words, then read them back the way
        // the PS does: write CAP_ADDR, read CAP_DATA
        bram[0]    = 32'h8000_0000 | 32'd60;      // R flag + CLT value
        bram[1]    = 32'h0000_0000 | 32'd72;
        bram[5]    = 32'h8000_0000 | 32'd15660;
        bram[1023] = 32'h0000_0000 | 32'd1234;

        axi_write(6'h30, 32'd5);
        axi_read (6'h34, rd);                check("CAP_DATA @5 (flag+clt)", rd, 32'h8000_3D2C);
        axi_write(6'h30, 32'd1);
        axi_read (6'h34, rd);                check("CAP_DATA @1", rd, 32'd72);
        axi_write(6'h30, 32'd1023);
        axi_read (6'h34, rd);                check("CAP_DATA @1023", rd, 32'd1234);
        axi_read (6'h30, rd);                check("CAP_ADDR read back", rd, 32'd1023);

        $display("------------------------------------------------------------------------");
        $display("checks = %0d   errors = %0d", checks, errs);
        if (errs == 0) $display("  RESULT: PASS");
        else           $display("  RESULT: FAIL");
        $display("========================================================================");
        $finish;
    end

endmodule
`default_nettype wire
