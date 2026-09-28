// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// 100G UDP echo on the RFSoC 4x2 with the XUP network layer (the stack of rfsoc_qsfp_offload),
// PL only (no processor): the whole datapath runs at the CMAC clock, 512 bit x 322 MHz.
//
//   CMAC RX -> RX frame FIFO -> network layer -> echo FIFO (payload + socket) -> network layer
//           -> TX frame FIFO -> CMAC TX
//
// A UDP payload that arrives on socket i (host HOST_IP, port HOST_PORT + i -> our port MY_PORT)
// goes back unchanged on socket i. nl_config fills in the addresses and the socket table after
// reset and runs ARP discovery once a second. The VIO shows per-second counters of every stage
// and gives JTAG access to the network layer registers.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module echo_top (
    input  wire clk_p,                   // 100 MHz
    input  wire clk_n,
    input  wire reset_n,                 // push button, active low

    output wire qsfp0_tx1_p, qsfp0_tx1_n,
    input  wire qsfp0_rx1_p, qsfp0_rx1_n,
    output wire qsfp0_tx2_p, qsfp0_tx2_n,
    input  wire qsfp0_rx2_p, qsfp0_rx2_n,
    output wire qsfp0_tx3_p, qsfp0_tx3_n,
    input  wire qsfp0_rx3_p, qsfp0_rx3_n,
    output wire qsfp0_tx4_p, qsfp0_tx4_n,
    input  wire qsfp0_rx4_p, qsfp0_rx4_n,
    input  wire qsfp0_mgt_refclk_0_p,
    input  wire qsfp0_mgt_refclk_0_n,
    output wire qsfp0_modsell,
    output wire qsfp0_resetl,
    input  wire qsfp0_modprsl,
    input  wire qsfp0_intl,
    output wire qsfp0_lpmode
);

localparam DW = 512, KW = DW / 8;
localparam MAC_HZ = 322265625;
localparam RX_FIFO_DEPTH   = 262144;     // bytes; ~28 jumbo frames
localparam ECHO_FIFO_DEPTH = 262144;

assign qsfp0_modsell = 1'b1;
assign qsfp0_resetl  = 1'b1;
assign qsfp0_lpmode  = 1'b0;

// ---------------------------------------------------------------- clocks
// 100 MHz -> MMCM (VCO 1000 MHz) -> 125 MHz: CMAC init / DRP clock
wire clk_in, clk_fb, mmcm_locked, clk_125_mmcm, clk_125, rst_125;

IBUFDS clk_in_ibufds (.I(clk_p), .IB(clk_n), .O(clk_in));

MMCME4_BASE #(
    .CLKIN1_PERIOD(10.0),
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(10.0),
    .CLKOUT0_DIVIDE_F(8.0),
    .BANDWIDTH("OPTIMIZED"),
    .STARTUP_WAIT("FALSE")
)
clk_mmcm (
    .CLKIN1(clk_in), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKFBOUTB(),
    .RST(~reset_n), .PWRDWN(1'b0),
    .CLKOUT0(clk_125_mmcm), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .LOCKED(mmcm_locked)
);

BUFG clk_125_bufg (.I(clk_125_mmcm), .O(clk_125));
sync_reset #(.N(4)) rst_125_sync (.clk(clk_125), .rst(~mmcm_locked), .out(rst_125));

// ---------------------------------------------------------------- CMAC
wire          mac_clk;                   // gt_txusrclk2, 322.265625 MHz; RX runs on it too
wire          mac_tx_rst, mac_rx_rst, rst;
wire [DW-1:0] mac_tx_tdata, mac_rx_tdata;
wire [KW-1:0] mac_tx_tkeep, mac_rx_tkeep;
wire          mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser;
wire          mac_rx_tvalid, mac_rx_tlast, mac_rx_tuser;

cmac_usplus_0 cmac_inst (
    .gt_rxp_in({qsfp0_rx4_p, qsfp0_rx3_p, qsfp0_rx2_p, qsfp0_rx1_p}),
    .gt_rxn_in({qsfp0_rx4_n, qsfp0_rx3_n, qsfp0_rx2_n, qsfp0_rx1_n}),
    .gt_txp_out({qsfp0_tx4_p, qsfp0_tx3_p, qsfp0_tx2_p, qsfp0_tx1_p}),
    .gt_txn_out({qsfp0_tx4_n, qsfp0_tx3_n, qsfp0_tx2_n, qsfp0_tx1_n}),
    .gt_ref_clk_p(qsfp0_mgt_refclk_0_p),
    .gt_ref_clk_n(qsfp0_mgt_refclk_0_n),
    .gt_txusrclk2(mac_clk),
    .gt_loopback_in(12'd0),
    .gtwiz_reset_tx_datapath(1'b0),
    .gtwiz_reset_rx_datapath(1'b0),
    .sys_reset(rst_125),
    .init_clk(clk_125),
    .ctl_tx_rsfec_enable(1'b1),
    .ctl_rx_rsfec_enable(1'b1),
    .ctl_rsfec_ieee_error_indication_mode(1'b0),
    .ctl_rx_rsfec_enable_correction(1'b1),
    .ctl_rx_rsfec_enable_indication(1'b1),
    .rx_clk(mac_clk),
    .core_rx_reset(1'b0),
    .ctl_rx_enable(1'b1),
    .ctl_rx_force_resync(1'b0),
    .ctl_rx_test_pattern(1'b0),
    .usr_rx_reset(mac_rx_rst),
    .rx_axis_tvalid(mac_rx_tvalid),
    .rx_axis_tdata(mac_rx_tdata),
    .rx_axis_tlast(mac_rx_tlast),
    .rx_axis_tkeep(mac_rx_tkeep),
    .rx_axis_tuser(mac_rx_tuser),
    .core_tx_reset(1'b0),
    .ctl_tx_enable(1'b1),
    .ctl_tx_send_idle(1'b0),
    .ctl_tx_send_rfi(1'b0),
    .ctl_tx_send_lfi(1'b0),
    .ctl_tx_test_pattern(1'b0),
    .usr_tx_reset(mac_tx_rst),
    .tx_axis_tvalid(mac_tx_tvalid),
    .tx_axis_tready(mac_tx_tready),
    .tx_axis_tdata(mac_tx_tdata),
    .tx_axis_tlast(mac_tx_tlast),
    .tx_axis_tkeep(mac_tx_tkeep),
    .tx_axis_tuser(mac_tx_tuser),
    .tx_preamblein(56'd0),
    .core_drp_reset(1'b0),
    .drp_clk(1'b0),
    .drp_addr(10'd0),
    .drp_di(16'd0),
    .drp_en(1'b0),
    .drp_we(1'b0)
);

sync_reset #(.N(4)) rst_mac_sync (.clk(mac_clk), .rst(mac_tx_rst || mac_rx_rst), .out(rst));

// ---------------------------------------------------------------- RX frame FIFO
// The CMAC cannot be back-pressured: whole frames are dropped when the FIFO is full, and
// frames with a bad FCS are dropped here too.
wire [DW-1:0] nl_rx_tdata;
wire [KW-1:0] nl_rx_tkeep;
wire          nl_rx_tvalid, nl_rx_tready, nl_rx_tlast;
wire          rxf_overflow, rxf_bad_frame;

axis_fifo #(
    .DEPTH(RX_FIFO_DEPTH), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .USER_BAD_FRAME_VALUE(1'b1), .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1)
)
rx_fifo (
    .clk(mac_clk), .rst(rst),
    .s_axis_tdata(mac_rx_tdata), .s_axis_tkeep(mac_rx_tkeep), .s_axis_tvalid(mac_rx_tvalid),
    .s_axis_tready(), .s_axis_tlast(mac_rx_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
    .s_axis_tuser(mac_rx_tuser),
    .m_axis_tdata(nl_rx_tdata), .m_axis_tkeep(nl_rx_tkeep), .m_axis_tvalid(nl_rx_tvalid),
    .m_axis_tready(nl_rx_tready), .m_axis_tlast(nl_rx_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(),
    .status_overflow(rxf_overflow),
    .status_bad_frame(rxf_bad_frame), .status_good_frame()
);

// ---------------------------------------------------------------- network layer
wire [DW-1:0] nl_tx_tdata, sk_rx_tdata, sk_tx_tdata;
wire [KW-1:0] nl_tx_tkeep, sk_rx_tkeep, sk_tx_tkeep;
wire [15:0]   sk_rx_tdest, sk_tx_tdest;
wire          nl_tx_tvalid, nl_tx_tready, nl_tx_tlast;
wire          sk_rx_tvalid, sk_rx_tready, sk_rx_tlast;
wire          sk_tx_tvalid, sk_tx_tready, sk_tx_tlast;

wire [15:0] axil_awaddr, axil_araddr;
wire [31:0] axil_wdata, axil_rdata;
wire [3:0]  axil_wstrb;
wire [1:0]  axil_bresp, axil_rresp;
wire        axil_awvalid, axil_awready, axil_wvalid, axil_wready, axil_bvalid, axil_bready;
wire        axil_arvalid, axil_arready, axil_rvalid, axil_rready;

networklayer_0 nl_inst (
    .ap_clk(mac_clk),
    .ap_rst_n(!rst),
    .S_AXIS_eth2nl_tdata(nl_rx_tdata), .S_AXIS_eth2nl_tkeep(nl_rx_tkeep),
    .S_AXIS_eth2nl_tvalid(nl_rx_tvalid), .S_AXIS_eth2nl_tready(nl_rx_tready),
    .S_AXIS_eth2nl_tlast(nl_rx_tlast),
    .M_AXIS_nl2eth_tdata(nl_tx_tdata), .M_AXIS_nl2eth_tkeep(nl_tx_tkeep),
    .M_AXIS_nl2eth_tvalid(nl_tx_tvalid), .M_AXIS_nl2eth_tready(nl_tx_tready),
    .M_AXIS_nl2eth_tlast(nl_tx_tlast),
    .S_AXIS_sk2nl_tdata(sk_tx_tdata), .S_AXIS_sk2nl_tkeep(sk_tx_tkeep),
    .S_AXIS_sk2nl_tvalid(sk_tx_tvalid), .S_AXIS_sk2nl_tready(sk_tx_tready),
    .S_AXIS_sk2nl_tlast(sk_tx_tlast), .S_AXIS_sk2nl_tdest(sk_tx_tdest),
    .M_AXIS_nl2sk_tdata(sk_rx_tdata), .M_AXIS_nl2sk_tkeep(sk_rx_tkeep),
    .M_AXIS_nl2sk_tvalid(sk_rx_tvalid), .M_AXIS_nl2sk_tready(sk_rx_tready),
    .M_AXIS_nl2sk_tlast(sk_rx_tlast), .M_AXIS_nl2sk_tdest(sk_rx_tdest), .M_AXIS_nl2sk_tuser(),
    .S_AXIL_nl_awaddr(axil_awaddr), .S_AXIL_nl_awvalid(axil_awvalid), .S_AXIL_nl_awready(axil_awready),
    .S_AXIL_nl_wdata(axil_wdata), .S_AXIL_nl_wstrb(axil_wstrb), .S_AXIL_nl_wvalid(axil_wvalid),
    .S_AXIL_nl_wready(axil_wready), .S_AXIL_nl_bresp(axil_bresp), .S_AXIL_nl_bvalid(axil_bvalid),
    .S_AXIL_nl_bready(axil_bready), .S_AXIL_nl_araddr(axil_araddr), .S_AXIL_nl_arvalid(axil_arvalid),
    .S_AXIL_nl_arready(axil_arready), .S_AXIL_nl_rdata(axil_rdata), .S_AXIL_nl_rresp(axil_rresp),
    .S_AXIL_nl_rvalid(axil_rvalid), .S_AXIL_nl_rready(axil_rready)
);

// ---------------------------------------------------------------- echo
// received payload with its socket index goes straight back out on the same socket; the
// network layer is never back-pressured by the echo, whole packets are dropped when full
wire echo_drop, echo_good;

axis_fifo #(
    .DEPTH(ECHO_FIFO_DEPTH), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(1), .DEST_WIDTH(16), .USER_ENABLE(0),
    .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(0), .DROP_WHEN_FULL(1)
)
echo_fifo (
    .clk(mac_clk), .rst(rst),
    .s_axis_tdata(sk_rx_tdata), .s_axis_tkeep(sk_rx_tkeep), .s_axis_tvalid(sk_rx_tvalid),
    .s_axis_tready(sk_rx_tready), .s_axis_tlast(sk_rx_tlast), .s_axis_tid(8'd0),
    .s_axis_tdest(sk_rx_tdest), .s_axis_tuser(1'b0),
    .m_axis_tdata(sk_tx_tdata), .m_axis_tkeep(sk_tx_tkeep), .m_axis_tvalid(sk_tx_tvalid),
    .m_axis_tready(sk_tx_tready), .m_axis_tlast(sk_tx_tlast), .m_axis_tid(),
    .m_axis_tdest(sk_tx_tdest), .m_axis_tuser(),
    .status_overflow(echo_drop),
    .status_bad_frame(), .status_good_frame(echo_good)
);

// ---------------------------------------------------------------- TX frame FIFO
// store and forward: the CMAC needs every frame without gaps
wire [DW-1:0] txf_tdata;
wire [KW-1:0] txf_tkeep;
wire          txf_tvalid, txf_tready, txf_tlast, txf_tuser;

axis_fifo #(
    .DEPTH(32768), .DATA_WIDTH(DW), .KEEP_ENABLE(1), .KEEP_WIDTH(KW), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(0), .DROP_WHEN_FULL(0)
)
tx_fifo (
    .clk(mac_clk), .rst(rst),
    .s_axis_tdata(nl_tx_tdata), .s_axis_tkeep(nl_tx_tkeep), .s_axis_tvalid(nl_tx_tvalid),
    .s_axis_tready(nl_tx_tready), .s_axis_tlast(nl_tx_tlast), .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0), .s_axis_tuser(1'b0),
    .m_axis_tdata(txf_tdata), .m_axis_tkeep(txf_tkeep), .m_axis_tvalid(txf_tvalid),
    .m_axis_tready(txf_tready), .m_axis_tlast(txf_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(txf_tuser),
    .status_overflow(), .status_bad_frame(),
    .status_good_frame()
);

eth_pad_min #(.DATA_WIDTH(DW)) tx_pad (
    .clk(mac_clk), .rst(rst),
    .s_axis_tdata(txf_tdata), .s_axis_tkeep(txf_tkeep), .s_axis_tvalid(txf_tvalid),
    .s_axis_tready(txf_tready), .s_axis_tlast(txf_tlast), .s_axis_tuser(txf_tuser),
    .m_axis_tdata(mac_tx_tdata), .m_axis_tkeep(mac_tx_tkeep), .m_axis_tvalid(mac_tx_tvalid),
    .m_axis_tready(mac_tx_tready), .m_axis_tlast(mac_tx_tlast), .m_axis_tuser(mac_tx_tuser)
);

// ---------------------------------------------------------------- configuration
wire        cfg_toggle, cfg_we, arp_enable;
wire [15:0] cfg_addr;
wire [31:0] cfg_wdata, cfg_rdata;
wire [7:0]  cfg_count;
wire [15:0] arp_count;
wire        init_done;

nl_config #(.ARP_PERIOD(MAC_HZ)) cfg_inst (
    .clk(mac_clk), .rst(rst),
    .arp_enable(arp_enable), .cmd_toggle(cfg_toggle), .cmd_we(cfg_we), .cmd_addr(cfg_addr),
    .cmd_wdata(cfg_wdata), .cmd_rdata(cfg_rdata), .cmd_count(cfg_count),
    .init_done(init_done), .arp_count(arp_count),
    .m_axil_awaddr(axil_awaddr), .m_axil_awvalid(axil_awvalid), .m_axil_awready(axil_awready),
    .m_axil_wdata(axil_wdata), .m_axil_wstrb(axil_wstrb), .m_axil_wvalid(axil_wvalid),
    .m_axil_wready(axil_wready), .m_axil_bresp(axil_bresp), .m_axil_bvalid(axil_bvalid),
    .m_axil_bready(axil_bready), .m_axil_araddr(axil_araddr), .m_axil_arvalid(axil_arvalid),
    .m_axil_arready(axil_arready), .m_axil_rdata(axil_rdata), .m_axil_rresp(axil_rresp),
    .m_axil_rvalid(axil_rvalid), .m_axil_rready(axil_rready)
);

// ---------------------------------------------------------------- per-second counters (VIO)
function [6:0] keep_bytes(input [KW-1:0] k);
    integer i;
    begin
        keep_bytes = 7'd0;
        for (i = 0; i < KW; i = i + 1) keep_bytes = keep_bytes + k[i];
    end
endfunction

wire [31:0] c_mac_rx, c_mac_rx_bad, c_rxf_drop, c_rxf_bad, c_nl_rx, c_nl_rx_stall, c_app_rx,
            c_echo_drop, c_echo_good, c_app_tx_stall, c_nl_tx, c_mac_tx;
wire [39:0] c_mac_tx_bytes;

rate_counter #(.CLK_HZ(MAC_HZ)) r0 (.clk(mac_clk), .rst(rst), .inc(mac_rx_tvalid && mac_rx_tlast), .rate(c_mac_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r1 (.clk(mac_clk), .rst(rst), .inc(mac_rx_tvalid && mac_rx_tlast && mac_rx_tuser), .rate(c_mac_rx_bad));
rate_counter #(.CLK_HZ(MAC_HZ)) r2 (.clk(mac_clk), .rst(rst), .inc(rxf_overflow), .rate(c_rxf_drop));
rate_counter #(.CLK_HZ(MAC_HZ)) r3 (.clk(mac_clk), .rst(rst), .inc(rxf_bad_frame), .rate(c_rxf_bad));
rate_counter #(.CLK_HZ(MAC_HZ)) r4 (.clk(mac_clk), .rst(rst), .inc(nl_rx_tvalid && nl_rx_tready && nl_rx_tlast), .rate(c_nl_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r5 (.clk(mac_clk), .rst(rst), .inc(nl_rx_tvalid && !nl_rx_tready), .rate(c_nl_rx_stall));
rate_counter #(.CLK_HZ(MAC_HZ)) r6 (.clk(mac_clk), .rst(rst), .inc(sk_rx_tvalid && sk_rx_tready && sk_rx_tlast), .rate(c_app_rx));
rate_counter #(.CLK_HZ(MAC_HZ)) r7 (.clk(mac_clk), .rst(rst), .inc(echo_drop), .rate(c_echo_drop));
rate_counter #(.CLK_HZ(MAC_HZ)) r8 (.clk(mac_clk), .rst(rst), .inc(echo_good), .rate(c_echo_good));
rate_counter #(.CLK_HZ(MAC_HZ)) r9 (.clk(mac_clk), .rst(rst), .inc(sk_tx_tvalid && !sk_tx_tready), .rate(c_app_tx_stall));
rate_counter #(.CLK_HZ(MAC_HZ)) r10 (.clk(mac_clk), .rst(rst), .inc(nl_tx_tvalid && nl_tx_tready && nl_tx_tlast), .rate(c_nl_tx));
rate_counter #(.CLK_HZ(MAC_HZ)) r11 (.clk(mac_clk), .rst(rst), .inc(mac_tx_tvalid && mac_tx_tready && mac_tx_tlast), .rate(c_mac_tx));
rate_counter #(.CLK_HZ(MAC_HZ), .INC_WIDTH(7), .WIDTH(40)) r12 (.clk(mac_clk), .rst(rst),
    .inc((mac_tx_tvalid && mac_tx_tready) ? keep_bytes(mac_tx_tkeep) : 7'd0), .rate(c_mac_tx_bytes));

wire [31:0] cfg_status = {arp_count, cfg_count, 7'd0, init_done};

vio_0 vio_inst (
    .clk(mac_clk),
    .probe_in0(c_mac_rx), .probe_in1(c_mac_rx_bad), .probe_in2(c_rxf_drop), .probe_in3(c_rxf_bad),
    .probe_in4(c_nl_rx), .probe_in5(c_nl_rx_stall), .probe_in6(c_app_rx), .probe_in7(c_echo_drop),
    .probe_in8(c_echo_good), .probe_in9(c_app_tx_stall), .probe_in10(c_nl_tx), .probe_in11(c_mac_tx),
    .probe_in12(c_mac_tx_bytes), .probe_in13(cfg_rdata), .probe_in14(cfg_status),
    .probe_out0(cfg_toggle), .probe_out1(cfg_we), .probe_out2(cfg_addr), .probe_out3(cfg_wdata),
    .probe_out4(arp_enable)
);

endmodule

`resetall
