`timescale 1ns / 1ps
`default_nettype none

// Verify that the continuous write pointer and the two-word-per-sample RAM
// mapping stay aligned over multiple ring wraps.
module tb_ring_memory;
    localparam integer N = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg run = 1'b0;
    reg soft_rst = 1'b0;
    reg [31:0] cap_len_in = 32'h8000_0000 | N;
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

    reg [31:0] ram [0:31];
    integer sample;
    integer errors = 0;
    integer position;
    integer expected_wave;

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

    // Models the BMG write port.  The RAM samples the previous cycle's outputs,
    // just like a synchronous BRAM.
    always @(posedge clk) begin
        if (cap_we) ram[cap_addr] <= cap_data;
    end

    task push_sample(input integer value);
    begin
        @(negedge clk);
        force dut.det_y = value[15:0];
        force dut.clt_out = 32'h0001_0000 + value;
        force dut.r_valid = value[0];
        force dut.clt_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        force dut.clt_valid = 1'b0;
        @(posedge clk);
        @(negedge clk);
        // The CLT word is registered one cycle after the waveform word.
        @(posedge clk);
        @(negedge clk);
    end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        run = 1'b1;

        for (sample = 0; sample < 4 * N; sample = sample + 1) begin
            push_sample(sample + 100);
            position = (st_clt_now[27:16] + N - 1) % N;
            expected_wave = sample + 100;
            if (ram[2 * position + 1][15:0] !== expected_wave) begin
                $display("FAIL sample=%0d ptr=%0d pos=%0d stored_wave=%0d expected=%0d",
                         sample, st_clt_now[27:16], position,
                         ram[2 * position + 1][15:0], expected_wave);
                errors = errors + 1;
            end
            if (ram[2 * position + 2] !== (32'h0001_0000 + sample + 100)) begin
                $display("FAIL sample=%0d ptr=%0d pos=%0d stored_clt=%08x expected=%08x",
                         sample, st_clt_now[27:16], position,
                         ram[2 * position + 2], 32'h0001_0000 + sample + 100);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS continuous RAM mapping remained aligned through 4 wraps");
        else
            $display("RESULT: FAIL errors=%0d", errors);
        $finish;
    end
endmodule

`default_nettype wire
