// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// AXI4-Lite master that configures the XUP network layer without a processor:
//   after reset: MAC, IP, gateway, mask and NSOCK sockets (theirIP HOST_IP, theirPort
//   HOST_PORT + i, myPort MY_PORT), then ARP_SCANS ARP discoveries (a 0-1-0 pulse on its
//   register) ARP_PERIOD cycles apart, and after that one every ARP_PERIOD only while
//   arp_enable is set. A discovery that starts while the network layer is sending races with
//   its per-packet MAC lookups (genARPDiscovery takes a lookup response for its own and the
//   Ethernet header inserter waits forever), so none runs under traffic unless asked for;
//   at any time after that: one register write or read per edge of cmd_toggle (VIO), the
//   read data in cmd_rdata, cmd_count counting finished commands.
// Register offsets are those of the network layer kernel (kernel.xml). Values are written as
// plain integers, the network layer puts them in network byte order itself.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module nl_config #(
    parameter [47:0] MAC        = 48'h02_00_00_00_00_80,
    parameter [31:0] IP         = {8'd192, 8'd168, 8'd100, 8'd128},
    parameter [31:0] GATEWAY    = {8'd192, 8'd168, 8'd100, 8'd1},
    parameter [31:0] MASK       = {8'd255, 8'd255, 8'd255, 8'd0},
    parameter [31:0] HOST_IP    = {8'd192, 8'd168, 8'd100, 8'd2},
    parameter [15:0] HOST_PORT  = 16'd6000,
    parameter [15:0] MY_PORT    = 16'd1234,
    parameter        NSOCK      = 16,
    parameter        ARP_PERIOD = 322265625,     // one second at the CMAC clock
    parameter        ARP_SCANS  = 3
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        arp_enable,
    input  wire        cmd_toggle,
    input  wire        cmd_we,
    input  wire [15:0] cmd_addr,
    input  wire [31:0] cmd_wdata,
    output reg  [31:0] cmd_rdata = 32'd0,
    output reg  [7:0]  cmd_count = 8'd0,
    output wire        init_done,
    output reg  [15:0] arp_count = 16'd0,

    output reg  [15:0] m_axil_awaddr = 16'd0,
    output reg         m_axil_awvalid = 1'b0,
    input  wire        m_axil_awready,
    output reg  [31:0] m_axil_wdata = 32'd0,
    output wire [3:0]  m_axil_wstrb,
    output reg         m_axil_wvalid = 1'b0,
    input  wire        m_axil_wready,
    input  wire [1:0]  m_axil_bresp,
    input  wire        m_axil_bvalid,
    output reg         m_axil_bready = 1'b0,
    output reg  [15:0] m_axil_araddr = 16'd0,
    output reg         m_axil_arvalid = 1'b0,
    input  wire        m_axil_arready,
    input  wire [31:0] m_axil_rdata,
    input  wire [1:0]  m_axil_rresp,
    input  wire        m_axil_rvalid,
    output reg         m_axil_rready = 1'b0
);

localparam [15:0] REG_MAC_LO = 16'h0010, REG_MAC_HI = 16'h0014, REG_IP = 16'h0018,
                  REG_GW = 16'h001C, REG_MASK = 16'h0020,
                  REG_THEIR_IP = 16'h0810, REG_THEIR_PORT = 16'h0890, REG_MY_PORT = 16'h0910,
                  REG_VALID = 16'h0990, REG_ARP_DISCOVERY = 16'h1010;
localparam NINIT = 5 + 4 * NSOCK;

assign m_axil_wstrb = 4'hF;

// initial register writes, in order
reg [7:0]  idx = 8'd0;
reg [15:0] init_addr;
reg [31:0] init_data;
integer s, f;
always @* begin
    init_addr = 16'd0;
    init_data = 32'd0;
    case (idx)
        0: begin init_addr = REG_MAC_LO; init_data = MAC[31:0]; end
        1: begin init_addr = REG_MAC_HI; init_data = {16'd0, MAC[47:32]}; end
        2: begin init_addr = REG_IP;     init_data = IP; end
        3: begin init_addr = REG_GW;     init_data = GATEWAY; end
        4: begin init_addr = REG_MASK;   init_data = MASK; end
        default: begin
            s = (idx - 5) / 4;
            f = (idx - 5) % 4;
            case (f)
                0: begin init_addr = REG_THEIR_IP   + s * 8; init_data = HOST_IP; end
                1: begin init_addr = REG_THEIR_PORT + s * 8; init_data = HOST_PORT + s; end
                2: begin init_addr = REG_MY_PORT    + s * 8; init_data = MY_PORT; end
                default: begin init_addr = REG_VALID + s * 8; init_data = 32'd1; end
            endcase
        end
    endcase
end

localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_WRITE = 3'd2, S_WRESP = 3'd3,
                 S_READ = 3'd4, S_RDATA = 3'd5;
reg [2:0]  state = S_INIT;
reg        done = 1'b0;
reg [1:0]  arp_step = 2'd0;          // ARP pulse: writes 0, 1, 0 in turn
reg        arp_active = 1'b0;
reg [31:0] arp_timer = 32'd0;
reg        tog_d = 1'b0;
reg        user_cmd = 1'b0;          // the transaction in flight is a VIO command

assign init_done = done;

task start_write(input [15:0] a, input [31:0] d);
    begin
        m_axil_awaddr <= a; m_axil_awvalid <= 1'b1;
        m_axil_wdata <= d;  m_axil_wvalid <= 1'b1;
        state <= S_WRITE;
    end
endtask

always @(posedge clk) begin
    if (arp_timer != 0) arp_timer <= arp_timer - 1;
    case (state)
        S_INIT: begin
            if (idx == NINIT) begin
                done <= 1'b1;
                state <= S_IDLE;
            end else begin
                start_write(init_addr, init_data);
            end
        end
        S_IDLE: begin
            if (cmd_toggle != tog_d) begin
                tog_d <= cmd_toggle;
                user_cmd <= 1'b1;
                if (cmd_we) begin
                    start_write(cmd_addr, cmd_wdata);
                end else begin
                    m_axil_araddr <= cmd_addr; m_axil_arvalid <= 1'b1;
                    state <= S_READ;
                end
            end else if (arp_active || ((arp_enable || arp_count < ARP_SCANS) && arp_timer == 0)) begin
                if (!arp_active) begin arp_active <= 1'b1; arp_timer <= ARP_PERIOD; end
                start_write(REG_ARP_DISCOVERY, {31'd0, arp_step == 2'd1});
            end
        end
        S_WRITE: begin
            if (m_axil_awready) m_axil_awvalid <= 1'b0;
            if (m_axil_wready)  m_axil_wvalid  <= 1'b0;
            if ((!m_axil_awvalid || m_axil_awready) && (!m_axil_wvalid || m_axil_wready)) begin
                m_axil_bready <= 1'b1;
                state <= S_WRESP;
            end
        end
        S_WRESP: begin
            if (m_axil_bvalid) begin
                m_axil_bready <= 1'b0;
                if (!done) begin
                    idx <= idx + 8'd1;
                    state <= S_INIT;
                end else begin
                    if (user_cmd) begin
                        user_cmd <= 1'b0;
                        cmd_count <= cmd_count + 8'd1;
                    end else if (arp_step == 2'd2) begin
                        arp_step <= 2'd0;
                        arp_active <= 1'b0;
                        arp_count <= arp_count + 16'd1;
                    end else begin
                        arp_step <= arp_step + 2'd1;
                    end
                    state <= S_IDLE;
                end
            end
        end
        S_READ: begin
            if (m_axil_arready) begin
                m_axil_arvalid <= 1'b0;
                m_axil_rready <= 1'b1;
                state <= S_RDATA;
            end
        end
        S_RDATA: begin
            if (m_axil_rvalid) begin
                m_axil_rready <= 1'b0;
                cmd_rdata <= m_axil_rdata;
                user_cmd <= 1'b0;
                cmd_count <= cmd_count + 8'd1;
                state <= S_IDLE;
            end
        end
        default: state <= S_IDLE;
    endcase

    if (rst) begin
        state <= S_INIT;
        idx <= 8'd0;
        done <= 1'b0;
        arp_step <= 2'd0;
        arp_active <= 1'b0;
        arp_timer <= 32'd0;
        tog_d <= cmd_toggle;
        user_cmd <= 1'b0;
        m_axil_awvalid <= 1'b0;
        m_axil_wvalid <= 1'b0;
        m_axil_bready <= 1'b0;
        m_axil_arvalid <= 1'b0;
        m_axil_rready <= 1'b0;
    end
end

endmodule

`resetall
