![语言](https://img.shields.io/badge/语言-verilog_(IEEE1364_2001)-9A90FD.svg) ![网络层](https://img.shields.io/badge/网络层-XUP_Network_Layer_(HLS)-orange.svg) ![部署](https://img.shields.io/badge/部署-vivado_2023.2-FF1010.svg) ![板卡](https://img.shields.io/badge/板卡-RFSoC_4x2-blue.svg)

[English](#en) | [中文](#cn)

　

<span id="en">RFSoC 4x2 100G UDP Echo on the XUP Network Layer</span>
===========================

A 100GbE UDP echo on the RFSoC 4x2 (XCZU48DR-FFVG1517-2-E) QSFP28 port, built on the network layer of this repository ([rfsoc_qsfp_offload](../../../README.md): the XUP [Network Layer](https://github.com/Xilinx/xup_vitis_network_example) with its RFSoC 4x2 patches). The network layer is unchanged and runs on the CMAC clock as in the original design; the RF-ADC application is replaced by an echo: every UDP payload that arrives goes back unchanged on the same socket. PL only (no PYNQ image needed), configured and monitored over JTAG.

Result: **4K video (3840x2160 RGB24) at 400 fps = 79.77 Gbit/s each way, 4000/4000 frames byte-exact**, no drop at any stage of the FPGA.

　

| ![arch](./docs/img/arch_echo.svg) |
| :-------------------------------: |
| **Figure1** : echo data path      |

　

## Technical Features

* **512 bit × 322.27 MHz end to end** (165 Gbit/s raw): the network layer runs on the CMAC TX clock, so a 100G line never saturates it.
* **Echo without a processor**: `M_AXIS_nl2sk` (payload + socket index in `tdest`) → echo FIFO → `S_AXIS_sk2nl`; the network layer rebuilds the Ethernet/IP/UDP headers from the socket table and its ARP table.
* **Frame FIFOs**: 256 KB RX (whole frames dropped only when full or with a bad FCS), 256 KB echo (payload + socket), 32 KB store-and-forward TX in front of the CMAC.
* **`nl_config`**: an AXI4-Lite master that writes the MAC, IP, gateway, mask and 16 sockets after reset, then runs 3 ARP discoveries (1 s apart) before any traffic. Afterwards the ARP table fills from ARP replies to the network layer's own requests.
* **VIO**: per-second counters of every stage and read / write access to any network layer register from Vivado.

　

## Performance Test Results

Host: Core Ultra 7 265K, Mellanox ConnectX-4 (PCIe 3.0 x16), Ubuntu 24.04, DPDK 24.11.3 (mlx5), `host/dpdk_loopback` with 4 TX / 8 RX cores, 16 flows (one per socket), 8956-byte UDP payload (2779 packets per 4K frame), 10 s per rate. Every frame is reassembled and compared byte by byte with what was sent.

Stored reference (the 4K picture frames themselves):

| Frame rate | Gbit/s each way | Frames intact | Packets lost | Latency avg / max |
| :--------: | :-------------: | :-----------: | :----------: | :---------------: |
| 4K120      | 23.93           | 1200 / 1200   | 0            | 9.2 / 9.4 ms      |
| 4K200      | 39.88           | 2000 / 2000   | 0            | 5.1 / 7.4 ms      |
| 4K280      | 55.84           | 2800 / 2800   | 0            | 3.6 / 6.5 ms      |
| **4K320**  | **63.81**       | **3200 / 3200** | **0**      | 3.2 / 6.1 ms      |

Generated reference (payload computed from frame id and byte offset, so the host compares without reading reference frames from memory):

| Frame rate | Gbit/s each way | Frames intact   | Packets lost | Latency avg / max |
| :--------: | :-------------: | :-------------: | :----------: | :---------------: |
| **4K400**  | **79.77**       | **4000 / 4000** | **0**        | 2.6 / 3.0 ms      |

FPGA counters over the whole run (126 s with traffic, up to 80.14 Gbit/s out of the CMAC): 0 frames with a bad FCS, 0 RX FIFO drops, 0 cycles of network layer back-pressure on the RX FIFO, 0 echo FIFO drops. Beyond these rates every frame still comes back intact, but the host cannot send them on schedule; the host, not the FPGA, sets the limit.

| ![4k](./docs/img/4k_sent_received.png)                          |
| :-------------------------------------------------------------: |
| **Figure2** : a sent 4K frame and its echo at 320 fps (identical) |

Timing met at 322.27 MHz (WNS +0.018 ns, WHS +0.010 ns). Resources: 23,445 LUT (5.5 %), 54,987 FF, 29 BRAM, 18 URAM. Raw data: [docs/results](./docs/results).

　

## Addresses

| | |
| :-- | :-- |
| FPGA | `02:00:00:00:00:80`, `192.168.100.128/24`, UDP port 1234 |
| Host | `192.168.100.2`, UDP ports 6000–6015 (socket 0–15) |

Change them in the parameters of `nl_config` (`rtl/echo_top.v`), or at runtime through the VIO register access.

　

## VIO

| Probe | Meaning |
| :---- | :------ |
| `c_mac_rx`, `c_mac_rx_bad` | CMAC RX frames / with a bad FCS, per second |
| `c_rxf_drop`, `c_rxf_bad` | RX FIFO drops (full / bad frame) |
| `c_nl_rx`, `c_nl_rx_stall` | frames into the network layer / cycles it held off the RX FIFO |
| `c_app_rx`, `c_echo_drop`, `c_echo_good`, `c_app_tx_stall` | payloads to the echo, echo FIFO drops, echoed packets, cycles the network layer held off the echo |
| `c_nl_tx`, `c_mac_tx`, `c_mac_tx_bytes` | frames out of the network layer, CMAC TX frames and bytes |
| `cfg_toggle`, `cfg_we`, `cfg_addr`, `cfg_wdata`, `cfg_rdata` | one network layer register write / read per toggle |
| `cfg_status` | `[31:16]` ARP discoveries, `[15:8]` register commands done, `[0]` configuration done |
| `arp_enable` | 1 = ARP discovery once a second (default 0; keep it off while traffic flows) |

　

## Build and Run

Vivado / Vitis HLS 2023.2 (the network layer IP is built once):

```
source /tools/Xilinx/Vivado/2023.2/settings64.sh; source /tools/Xilinx/Vitis_HLS/2023.2/settings64.sh
git clone --recursive https://github.com/uceeyuf/rfsoc_qsfp_offload.git
cd rfsoc_qsfp_offload
make patch
make build_ip VIVADO_VERSION=2023.2
cd boards/RFSoC4x2/qsfp_udp_echo
vivado -mode batch -source scripts/build.tcl -tclargs 16        # build/echo.bit, build/echo.ltx
vivado -mode batch -source tests/echo_stats.tcl -tclargs 30 1   # program over JTAG, configuration + counters
```

Host (Linux, DPDK 24.11 with the mlx5 driver):

```
IF=enp2s0np0
sudo ethtool -s $IF speed 100000 autoneg off
sudo ethtool --set-fec $IF encoding rs
sudo ip link set $IF up mtu 9000
echo 1536 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
host/dpdk_loopback/build.sh
sudo host/dpdk_loopback/dpdk_loopback -l 0-12 -a 0000:02:00.0 -- --one-ip --rxq 8 \
     --sweep 120,160,200,240,280,320 --out out_4k                    # stored reference
sudo host/dpdk_loopback/dpdk_loopback -l 0-12 -a 0000:02:00.0 -- --one-ip --rxq 8 \
     --ref gen --fps 400 --out out_4k400                            # generated reference
```

`--one-ip` sends all 16 flows to `192.168.100.128` (source ports 6000–6015, one socket each). `out_*/summary.txt` has one line per rate; `sent.ppm` / `received.ppm` are a frame and its echo at the highest passing rate.

　

## License

The files of this design (`rtl/`, `scripts/`, `tests/`, `host/`, `ip/`, `constraints/`, `docs/`) are BSD 3-Clause, Copyright (c) 2026, Yijie Yu. The network layer (Xilinx, HPCN-UAM) and rfsoc_qsfp_offload (University of Strathclyde) are BSD 3-Clause under their own copyright; verilog-ethernet (submodule, `274831c`) is MIT.

　

　

<span id="cn">基于 XUP Network Layer 的 RFSoC 4x2 100G UDP 回环</span>
===========================

在 RFSoC 4x2（XCZU48DR-FFVG1517-2-E）QSFP28 口上的 100GbE UDP 回环，网络层直接使用本仓库（[rfsoc_qsfp_offload](../../../README.md)）的 XUP [Network Layer](https://github.com/Xilinx/xup_vitis_network_example) 及其 RFSoC 4x2 补丁。网络层保持不变，并与原设计一样运行在 CMAC 时钟上；只把 RF-ADC 应用换成回环：收到的每个 UDP 负载原样从同一个 socket 发回。纯 PL 设计（无需 PYNQ 镜像），通过 JTAG 配置和监测。

结果：**4K 视频（3840x2160 RGB24）400 fps = 单向 79.77 Gbit/s，4000/4000 帧逐字节一致**，FPGA 各级均无丢包。

　

| ![arch](./docs/img/arch_echo.svg) |
| :-------------------------------: |
| **图1** : 回环数据通路             |

　

## 技术特点

* **全程 512 bit × 322.27 MHz**（原始带宽 165 Gbit/s）：网络层直接运行在 CMAC TX 时钟上，100G 线速下远未饱和。
* **无处理器回环**：`M_AXIS_nl2sk`（负载 + `tdest` 中的 socket 编号）→ 回环 FIFO → `S_AXIS_sk2nl`；网络层依据 socket 表和 ARP 表重建以太网/IP/UDP 头。
* **帧 FIFO**：256 KB 接收（仅在满或 FCS 错误时整帧丢弃），256 KB 回环（负载 + socket），CMAC 前 32 KB 存储转发发送。
* **`nl_config`**：AXI4-Lite 主机，复位后写入 MAC、IP、网关、掩码和 16 个 socket，并在流量到来前做 3 次 ARP 发现（间隔 1 s）；之后 ARP 表由网络层自身请求的应答填充。
* **VIO**：各级每秒计数，以及在 Vivado 中读写任意网络层寄存器。

　

## 性能测试结果

主机：Core Ultra 7 265K，Mellanox ConnectX-4（PCIe 3.0 x16），Ubuntu 24.04，DPDK 24.11.3（mlx5），`host/dpdk_loopback`，4 个发送核 / 8 个接收核，16 条流（每个 socket 一条），UDP 负载 8956 字节（每帧 4K 2779 个包），每个帧率 10 s。每一帧都重组并与发送内容逐字节比较。

存储参考（直接比较 4K 图像帧）：

| 帧率       | 单向 Gbit/s | 完整帧          | 丢包   | 平均 / 最大延迟 |
| :--------: | :---------: | :-------------: | :----: | :-------------: |
| 4K120      | 23.93       | 1200 / 1200     | 0      | 9.2 / 9.4 ms    |
| 4K200      | 39.88       | 2000 / 2000     | 0      | 5.1 / 7.4 ms    |
| 4K280      | 55.84       | 2800 / 2800     | 0      | 3.6 / 6.5 ms    |
| **4K320**  | **63.81**   | **3200 / 3200** | **0**  | 3.2 / 6.1 ms    |

生成参考（负载由帧号和字节偏移计算得到，主机比较时无需从内存读取参考帧）：

| 帧率       | 单向 Gbit/s | 完整帧          | 丢包   | 平均 / 最大延迟 |
| :--------: | :---------: | :-------------: | :----: | :-------------: |
| **4K400**  | **79.77**   | **4000 / 4000** | **0**  | 2.6 / 3.0 ms    |

整个测试期间的 FPGA 计数（126 s 有流量，CMAC 输出最高 80.14 Gbit/s）：FCS 错误帧 0，接收 FIFO 丢帧 0，网络层对接收 FIFO 的反压周期 0，回环 FIFO 丢包 0。更高帧率下所有帧仍完整返回，但主机无法按时发出；瓶颈在主机，不在 FPGA。

| ![4k](./docs/img/4k_sent_received.png)                |
| :---------------------------------------------------: |
| **图2** : 发送的一帧 4K 画面与 320 fps 下的回环（完全一致） |

322.27 MHz 时序收敛（WNS +0.018 ns，WHS +0.010 ns）。资源：23,445 LUT（5.5 %），54,987 FF，29 BRAM，18 URAM。原始数据：[docs/results](./docs/results)。

　

## 地址

| | |
| :-- | :-- |
| FPGA | `02:00:00:00:00:80`，`192.168.100.128/24`，UDP 端口 1234 |
| 主机 | `192.168.100.2`，UDP 端口 6000–6015（socket 0–15） |

可在 `rtl/echo_top.v` 中 `nl_config` 的参数里修改，或运行时通过 VIO 寄存器访问修改。

　

## VIO

| 探针 | 含义 |
| :--- | :--- |
| `c_mac_rx`、`c_mac_rx_bad` | 每秒 CMAC 接收帧 / 其中 FCS 错误 |
| `c_rxf_drop`、`c_rxf_bad` | 接收 FIFO 丢帧（满 / 坏帧） |
| `c_nl_rx`、`c_nl_rx_stall` | 进入网络层的帧 / 网络层反压接收 FIFO 的周期 |
| `c_app_rx`、`c_echo_drop`、`c_echo_good`、`c_app_tx_stall` | 交给回环的负载、回环 FIFO 丢包、回环包数、网络层反压回环的周期 |
| `c_nl_tx`、`c_mac_tx`、`c_mac_tx_bytes` | 网络层输出帧、CMAC 发送帧与字节 |
| `cfg_toggle`、`cfg_we`、`cfg_addr`、`cfg_wdata`、`cfg_rdata` | 每翻转一次执行一次网络层寄存器写 / 读 |
| `cfg_status` | `[31:16]` ARP 发现次数，`[15:8]` 已完成的寄存器命令，`[0]` 配置完成 |
| `arp_enable` | 1 = 每秒一次 ARP 发现（默认 0；有流量时保持关闭） |

　

## 编译与运行

Vivado / Vitis HLS 2023.2（网络层 IP 只需编译一次）：

```
source /tools/Xilinx/Vivado/2023.2/settings64.sh; source /tools/Xilinx/Vitis_HLS/2023.2/settings64.sh
git clone --recursive https://github.com/uceeyuf/rfsoc_qsfp_offload.git
cd rfsoc_qsfp_offload
make patch
make build_ip VIVADO_VERSION=2023.2
cd boards/RFSoC4x2/qsfp_udp_echo
vivado -mode batch -source scripts/build.tcl -tclargs 16        # build/echo.bit、build/echo.ltx
vivado -mode batch -source tests/echo_stats.tcl -tclargs 30 1   # JTAG 下载，读回配置并打印计数
```

主机（Linux，DPDK 24.11，mlx5 驱动）：

```
IF=enp2s0np0
sudo ethtool -s $IF speed 100000 autoneg off
sudo ethtool --set-fec $IF encoding rs
sudo ip link set $IF up mtu 9000
echo 1536 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
host/dpdk_loopback/build.sh
sudo host/dpdk_loopback/dpdk_loopback -l 0-12 -a 0000:02:00.0 -- --one-ip --rxq 8 \
     --sweep 120,160,200,240,280,320 --out out_4k                    # 存储参考
sudo host/dpdk_loopback/dpdk_loopback -l 0-12 -a 0000:02:00.0 -- --one-ip --rxq 8 \
     --ref gen --fps 400 --out out_4k400                            # 生成参考
```

`--one-ip` 让 16 条流都发往 `192.168.100.128`（源端口 6000–6015，各对应一个 socket）。`out_*/summary.txt` 每个帧率一行；`sent.ppm` / `received.ppm` 是最高通过帧率下的一帧及其回环。

　

## 许可证

本设计的文件（`rtl/`、`scripts/`、`tests/`、`host/`、`ip/`、`constraints/`、`docs/`）采用 BSD 3-Clause，版权所有 (c) 2026 Yijie Yu。网络层（Xilinx、HPCN-UAM）与 rfsoc_qsfp_offload（University of Strathclyde）按各自版权采用 BSD 3-Clause；verilog-ethernet（子模块，`274831c`）为 MIT。
