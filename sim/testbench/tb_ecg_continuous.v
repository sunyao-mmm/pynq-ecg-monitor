`timescale 1ns / 1ps
`default_nettype none

// Focused test for capture buffer behavior.  The normal 22-check tb_ecg_core
// separately verifies the complete ECG algorithm.
module tb_ecg_continuous;
    localparam integer N = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg run = 1'b0;
    reg soft_rst = 1'b0;
    reg [31:0] cap_len_in = 0;
    reg src_sel = 1'b0;
    reg signed [15:0] adc_sample = 0;
    reg adc_valid = 0;

    wire [5:0] rom_addr;
    reg signed [15:0] rom_data = 0;
    wire cap_we;
    wire [3:0] cap_addr;
    wire [31:0] cap_data;
    wire [31:0] st_clt_now;
    wire [31:0] st_r_index;
    wire [15:0] st_r_amp;
    wire [15:0] st_bpm;
    wire [31:0] st_rr_samples;
    wire [31:0] st_beat_count;
    wire [31:0] st_rr_bad_cnt;
    wire st_cap_done;

    ecg_core #(
        .CLK_PER_SAMPLE(100000),
        .ROM_LEN(N),
        .ROM_AW(6),
        .CAP_AW(4),
        .ROM_SETTLE(1),
        .SETTLE(0),
        .CAL_FIRST(0)
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

    integer errors = 0;
    integer i;
    integer ptr_seen [0:N-1];
    integer seen_all;
    integer writes;
    reg [3:0] frozen_addr;
    reg [31:0] frozen_data;

    task force_sample;
    begin
        @(negedge clk);
        force dut.det_y = 16'sd123;
        force dut.clt_out = 32'd456;
        force dut.r_valid = 1'b0;
        force dut.clt_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        force dut.clt_valid = 1'b0;
        @(posedge clk);
        @(negedge clk);
    end
    endtask

    always @(posedge clk) begin
        if (rst_n && run && cap_we) writes = writes + 1;
        if (rst_n && run && st_clt_now[27:16] < N)
            ptr_seen[st_clt_now[27:16]] = 1;
    end

    initial begin
        for (i = 0; i < N; i = i + 1) ptr_seen[i] = 0;
        writes = 0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Preserved normal mode: exactly N samples and cap_done.
        cap_len_in = N;
        soft_rst = 1'b1;
        @(negedge clk);
        soft_rst = 1'b0;
        run = 1'b1;
        repeat (N) force_sample();
        if (!st_cap_done) begin
            $display("FAIL normal mode did not assert cap_done");
            errors = errors + 1;
        end else begin
            $display("PASS normal capture stopped at CAP_LEN");
        end
        frozen_addr = cap_addr;
        frozen_data = cap_data;
        repeat (4) force_sample();
        if (cap_addr !== frozen_addr || cap_data !== frozen_data) begin
            $display("FAIL normal capture changed after cap_done");
            errors = errors + 1;
        end else begin
            $display("PASS normal capture remained frozen");
        end

        // Continuous ring: CAP_LEN[31]=1, six logical positions, address 0 hole.
        run = 1'b0;
        repeat (2) @(negedge clk);
        cap_len_in = 32'h8000_0000 | N;
        soft_rst = 1'b1;
        @(negedge clk);
        soft_rst = 1'b0;
        run = 1'b1;
        for (i = 0; i < 18; i = i + 1) begin
            force_sample();
            if (st_cap_done) begin
                $display("FAIL continuous mode asserted cap_done");
                errors = errors + 1;
                i = 18;
            end
            if (cap_addr > (2*N)) begin
                $display("FAIL continuous address exceeded ring: %0d", cap_addr);
                errors = errors + 1;
                i = 18;
            end
        end
        seen_all = 1;
        for (i = 0; i < N; i = i + 1)
            if (!ptr_seen[i]) seen_all = 0;
        if (!seen_all) begin
            $display("FAIL continuous ring position did not traverse all positions");
            errors = errors + 1;
        end else begin
            $display("PASS continuous ring wrapped through all positions");
        end
        $display("INFO cap_we pulses=%0d final_addr=%0d final_ptr=%0d",
                 writes, cap_addr, st_clt_now[27:16]);

        release dut.det_y;
        release dut.clt_out;
        release dut.r_valid;
        release dut.clt_valid;
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end
endmodule

`default_nettype wire
