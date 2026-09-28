# XUP network layer (ARP, ICMP, UDP with a 16-entry socket table), built by the top-level
# Makefile (make build_ip) into boards/ip_repo/xup_vitis_network_example/NetLayers.
create_ip -vlnv xilinx.com:RTLKernel:networklayer:1.0 -module_name networklayer_0
