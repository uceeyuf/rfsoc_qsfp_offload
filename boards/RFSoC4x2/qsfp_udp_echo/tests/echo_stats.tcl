# Watch the UDP echo stage by stage (per-second VIO counters) while a host sends.
#
#   vivado -mode batch -source tests/echo_stats.tcl -tclargs [seconds] [program] [arp]
#
# seconds: how long to print (default 30). program = 1 loads build/echo.bit first.
# arp = 0 / 1 turns the periodic ARP discovery off / on (left as it is if not given).
# First prints the configuration read back from the network layer (address, socket 0, the
# ARP entry of the host), then per second: CMAC RX frames, of them with a bad FCS, RX FIFO
# drops (full / bad frame), frames into the network layer, cycles it held off the RX FIFO,
# payloads to the echo, echo FIFO drops (full), echo packets, cycles the network layer held
# off the echo, frames out of the network layer, CMAC TX frames, CMAC TX Gbit/s.

set dir  [file normalize [file join [file dirname [info script]] ..]]
set secs [expr {$argc > 0 ? [lindex $argv 0] : 30}]
set prog [expr {$argc > 1 ? [lindex $argv 1] : 0}]
set arp  [expr {$argc > 2 ? [lindex $argv 2] : -1}]
set bit  [file join $dir build echo.bit]
set ltx  [file join $dir build echo.ltx]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xczu48dr*] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
if {$prog} {
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
}
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]

proc probe {name} {
    global vio
    set p [get_hw_probes $name -of_objects $vio]
    if {$p eq ""} { set p [get_hw_probes */$name -of_objects $vio] }
    return $p
}

# network layer register access through nl_config (VIO command interface)
set p_tog  [probe cfg_toggle]
set p_we   [probe cfg_we]
set p_addr [probe cfg_addr]
set p_wd   [probe cfg_wdata]
set p_rd   [probe cfg_rdata]
set p_stat [probe cfg_status]
foreach p [list $p_addr $p_wd] { set_property OUTPUT_VALUE_RADIX HEX $p }
foreach p [list $p_rd $p_stat] { set_property INPUT_VALUE_RADIX HEX $p }
proc status {} {
    global vio p_stat
    refresh_hw_vio $vio
    return [expr {"0x[get_property INPUT_VALUE $p_stat]"}]
}
proc reg_access {addr we {data 0}} {
    global vio p_tog p_we p_addr p_wd p_rd
    set n0 [expr {([status] >> 8) & 0xff}]
    set_property OUTPUT_VALUE [format %04x $addr] $p_addr
    set_property OUTPUT_VALUE $we $p_we
    set_property OUTPUT_VALUE [format %08x $data] $p_wd
    commit_hw_vio $vio
    set t [get_property OUTPUT_VALUE $p_tog]
    set_property OUTPUT_VALUE [expr {1 - $t}] $p_tog
    commit_hw_vio $vio
    for {set i 0} {$i < 50} {incr i} {
        if {(([status] >> 8) & 0xff) != $n0} break
        after 10
    }
    refresh_hw_vio $vio
    return [expr {"0x[get_property INPUT_VALUE $p_rd]"}]
}
proc reg_read {addr} { return [reg_access $addr 0] }
proc ip_str {v} { return [format "%d.%d.%d.%d" [expr {($v >> 24) & 255}] [expr {($v >> 16) & 255}] [expr {($v >> 8) & 255}] [expr {$v & 255}]] }

if {$arp >= 0} {
    if {$prog} { after 2500 }         ;# let the first discovery run after programming
    set p_arp [probe arp_enable]
    set_property OUTPUT_VALUE $arp $p_arp
    commit_hw_vio $vio
    puts "periodic ARP discovery [expr {$arp ? {on} : {off}}]"
}
after 500
set st [status]
puts [format "init done %d, ARP discoveries %d" [expr {$st & 1}] [expr {($st >> 16) & 0xffff}]]
puts [format "MAC %04x%08x  IP %s  gateway %s  mask %s  sockets %d" [reg_read 0x14] [reg_read 0x10] \
    [ip_str [reg_read 0x18]] [ip_str [reg_read 0x1C]] [ip_str [reg_read 0x20]] [reg_read 0xA10]]
puts [format "socket 0: their %s:%d  my port %d  valid %d" [ip_str [reg_read 0x810]] [reg_read 0x890] \
    [reg_read 0x910] [reg_read 0x990]]
# ARP table entry of the host (index = last octet of its address, 2): valid bytes, MAC words
set arpv [reg_read [expr {0x1100 + 0}]]
puts [format "ARP[2]: valid %d  MAC %08x %08x" [expr {($arpv >> 16) & 1}] [reg_read [expr {0x1800 + 2*8 + 4}]] [reg_read [expr {0x1800 + 2*8}]]]

set names {c_mac_rx c_mac_rx_bad c_rxf_drop c_rxf_bad c_nl_rx c_nl_rx_stall c_app_rx c_echo_drop
           c_echo_good c_app_tx_stall c_nl_tx c_mac_tx c_mac_tx_bytes}
foreach n $names {
    set p [probe $n]
    set_property INPUT_VALUE_RADIX UNSIGNED $p
    set pr($n) $p
}
puts [format "%4s %9s %6s %8s %6s %9s %9s %9s %9s %9s %9s %9s %9s %7s" \
    t mac_rx rx_bad rxf_drop rxf_bad nl_rx nl_stall app_rx echo_drop echo_pkts app_stall nl_tx mac_tx tx_Gbps]
for {set t 1} {$t <= $secs} {incr t} {
    after 1000
    refresh_hw_vio $vio
    foreach n $names { set v($n) [get_property INPUT_VALUE $pr($n)] }
    puts [format "%4d %9s %6s %8s %6s %9s %9s %9s %9s %9s %9s %9s %9s %7.2f" $t \
        $v(c_mac_rx) $v(c_mac_rx_bad) $v(c_rxf_drop) $v(c_rxf_bad) $v(c_nl_rx) $v(c_nl_rx_stall) \
        $v(c_app_rx) $v(c_echo_drop) $v(c_echo_good) $v(c_app_tx_stall) $v(c_nl_tx) $v(c_mac_tx) \
        [expr {$v(c_mac_tx_bytes) * 8 / 1e9}]]
    flush stdout
}
close_hw_manager
