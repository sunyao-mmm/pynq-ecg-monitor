`timescale 1ns / 1ps
`default_nettype none
// ecg_axil.v : AXI4-Lite register window (PS <-> PL).
// Register map (byte offsets): 0x00 CTRL(bit0 run, bit1 soft_rst, bit2 src_sel) 0x04 STATUS 0x08 CLT_NOW 0x0C R_INDEX
// 0x10 R_AMP 0x14 BPM 0x18 RR_SAMPLES 0x1C BEAT_COUNT 0x20 RR_BAD_CNT 0x24 CAP_LEN
// 0x28 SCRATCH 0x2C ID 0x30 CAP_ADDR 0x34 CAP_DATA
module ecg_axil #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6           // 64 bytes = 16 registers
)(
    // ---------------- AXI4-Lite slave ----------------
    // The (* X_INTERFACE_INFO *) attributes below let Vivado recognise this
    // module as an AXI4-Lite slave when you drop it into a block design with
    // "Add Module", so there is NO need to run the IP packaging wizard.
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ACLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN, FREQ_HZ 20000000, PHASE 0.0" *)
    input  wire                                S_AXI_ACLK,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_ARESETN, POLARITY ACTIVE_LOW" *)
    input  wire                                S_AXI_ARESETN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]                          S_AXI_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                                S_AXI_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire                                S_AXI_AWREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   S_AXI_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                                S_AXI_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire                                S_AXI_WREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]                          S_AXI_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire                                S_AXI_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                                S_AXI_BREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]                          S_AXI_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                                S_AXI_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire                                S_AXI_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]                          S_AXI_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire                                S_AXI_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                                S_AXI_RREADY,

    // ---------------- control out to the ECG core ----------------
    output wire                                ctrl_run,
    output wire                                ctrl_soft_rst,
    output wire                                ctrl_src,       // 0 = ROM, 1 = ADS1292
    output wire [31:0]                         cap_len,
    // ---------------- capture buffer read port (goes to BMG port B) ----------------
    output wire [11:0]                         cap_rd_addr,
    input  wire [31:0]                         cap_rd_data,
    // ---------------- status in from the ECG core ----------------
    input  wire [31:0]                         st_clt_now,
    input  wire [31:0]                         st_r_index,
    input  wire [15:0]                         st_r_amp,
    input  wire [15:0]                         st_bpm,
    input  wire [31:0]                         st_rr_samples,
    input  wire [31:0]                         st_beat_count,
    input  wire [31:0]                         st_rr_bad_cnt,
    input  wire                                st_cap_done
);

    localparam integer ADDR_LSB          = 2;                       // 32-bit registers
    localparam integer OPT_MEM_ADDR_BITS = 3;                       // 4 bits -> 16 regs

    localparam [31:0]  ID_VALUE          = 32'h0EC6_0001;

    reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                           axi_awready;
    reg                           axi_wready;
    reg  [1:0]                    axi_bresp;
    reg                           axi_bvalid;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg                           axi_arready;
    reg  [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg  [1:0]                    axi_rresp;
    reg                           axi_rvalid;
    reg                           aw_en;

    // ---------------- user registers ----------------
    reg  [31:0] ctrl_reg;
    reg  [31:0] cap_len_reg;
    reg  [31:0] scratch_reg;
    reg  [31:0] cap_addr_reg;      // 0x30 : capture buffer read address

    wire        wr_en = axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID;
    wire [3:0]  wr_idx = axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB];
    wire [3:0]  rd_idx = axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB];

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    assign ctrl_run      = ctrl_reg[0];
    assign ctrl_soft_rst = ctrl_reg[1];
    assign ctrl_src      = ctrl_reg[2];
    assign cap_len       = cap_len_reg;
    assign cap_rd_addr   = cap_addr_reg[11:0];

    // ---------------- read multiplexer ----------------
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;
    always @* begin
        case (rd_idx)
            4'h0: reg_data_out = ctrl_reg;
            4'h1: reg_data_out = {st_beat_count[15:0], 14'd0, st_cap_done, ctrl_reg[0]};
            4'h2: reg_data_out = st_clt_now;
            4'h3: reg_data_out = st_r_index;
            4'h4: reg_data_out = {16'd0, st_r_amp};
            4'h5: reg_data_out = {16'd0, st_bpm};
            4'h6: reg_data_out = st_rr_samples;
            4'h7: reg_data_out = st_beat_count;
            4'h8: reg_data_out = st_rr_bad_cnt;
            4'h9: reg_data_out = cap_len_reg;
            4'hA: reg_data_out = scratch_reg;
            4'hB: reg_data_out = ID_VALUE;
            4'hC: reg_data_out = cap_addr_reg;
            4'hD: reg_data_out = cap_rd_data;
            default: reg_data_out = 32'h0000_0000;
        endcase
    end

    // ---------------- AXI4-Lite write channel ----------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bresp   <= 2'b00;
            axi_bvalid  <= 1'b0;
            aw_en       <= 1'b1;
            axi_awaddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end
        else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                axi_awready <= 1'b1;
                axi_awaddr  <= S_AXI_AWADDR;
                aw_en       <= 1'b0;
            end
            else begin
                axi_awready <= 1'b0;
                if (S_AXI_BREADY && axi_bvalid) aw_en <= 1'b1;
            end

            if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) begin
                axi_wready <= 1'b1;
            end
            else begin
                axi_wready <= 1'b0;
            end

            if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end
            else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // ---------------- register write (byte enables honoured) ----------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            ctrl_reg     <= 32'd0;
            cap_len_reg  <= 32'd1024;
            scratch_reg  <= 32'h0000_0000;
            cap_addr_reg <= 32'd0;
        end
        else if (wr_en) begin
            case (wr_idx)
                4'h0: begin
                    if (S_AXI_WSTRB[0]) ctrl_reg[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) ctrl_reg[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) ctrl_reg[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) ctrl_reg[31:24] <= S_AXI_WDATA[31:24];
                end
                4'h9: begin
                    if (S_AXI_WSTRB[0]) cap_len_reg[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) cap_len_reg[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) cap_len_reg[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) cap_len_reg[31:24] <= S_AXI_WDATA[31:24];
                end
                4'hA: begin
                    if (S_AXI_WSTRB[0]) scratch_reg[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) scratch_reg[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) scratch_reg[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) scratch_reg[31:24] <= S_AXI_WDATA[31:24];
                end
                4'hC: begin
                    if (S_AXI_WSTRB[0]) cap_addr_reg[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) cap_addr_reg[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) cap_addr_reg[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) cap_addr_reg[31:24] <= S_AXI_WDATA[31:24];
                end
                default: ;   // read-only or unused
            endcase
        end
    end

    // ---------------- AXI4-Lite read channel ----------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end
        else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
            end
            else begin
                axi_arready <= 1'b0;
            end

            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
            end
            else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end

            axi_rdata <= reg_data_out;
        end
    end

endmodule
`default_nettype wire
