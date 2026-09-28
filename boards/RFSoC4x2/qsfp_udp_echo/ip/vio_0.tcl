# Per-second counters of the echo path and JTAG access to the network layer registers.
#   in0 CMAC RX frames, in1 of them with a bad FCS, in2 RX FIFO drops (full), in3 RX FIFO drops
#   (bad frame), in4 frames into the network layer, in5 cycles it back-pressured the RX FIFO,
#   in6 UDP payloads to the echo, in7 echo FIFO drops (full), in8 echo FIFO packets,
#   in9 cycles the network layer back-pressured the echo, in10 frames out of the network layer,
#   in11 CMAC TX frames, in12 CMAC TX bytes (40 bit),
#   in13 register read data, in14 {ARP discoveries[15:0], commands done[7:0], 7'b0, init done}
#   out0 command toggle, out1 write (1) / read (0), out2 register address, out3 write data,
#   out4 periodic ARP discovery enable (off: only ARP_SCANS discoveries after reset)
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {15} \
    CONFIG.C_PROBE_IN0_WIDTH {32} CONFIG.C_PROBE_IN1_WIDTH {32} CONFIG.C_PROBE_IN2_WIDTH {32} \
    CONFIG.C_PROBE_IN3_WIDTH {32} CONFIG.C_PROBE_IN4_WIDTH {32} CONFIG.C_PROBE_IN5_WIDTH {32} \
    CONFIG.C_PROBE_IN6_WIDTH {32} CONFIG.C_PROBE_IN7_WIDTH {32} CONFIG.C_PROBE_IN8_WIDTH {32} \
    CONFIG.C_PROBE_IN9_WIDTH {32} CONFIG.C_PROBE_IN10_WIDTH {32} CONFIG.C_PROBE_IN11_WIDTH {32} \
    CONFIG.C_PROBE_IN12_WIDTH {40} CONFIG.C_PROBE_IN13_WIDTH {32} CONFIG.C_PROBE_IN14_WIDTH {32} \
    CONFIG.C_NUM_PROBE_OUT {5} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {1} CONFIG.C_PROBE_OUT2_WIDTH {16} \
    CONFIG.C_PROBE_OUT3_WIDTH {32} CONFIG.C_PROBE_OUT4_WIDTH {1} CONFIG.C_PROBE_OUT4_INIT_VAL {0x0} \
    CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
] [get_ips vio_0]
