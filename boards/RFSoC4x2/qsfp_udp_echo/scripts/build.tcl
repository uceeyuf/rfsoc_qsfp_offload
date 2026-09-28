# Synthesize, implement and write the bitstream: build/echo.bit, build/echo.ltx
#   vivado -mode batch -source scripts/build.tcl [-tclargs <jobs>]
set dir  [file normalize [file join [file dirname [info script]] ..]]
set xpr  [file join $dir build qsfp_udp_echo qsfp_udp_echo.xpr]
set jobs [expr {$argc > 0 ? [lindex $argv 0] : 8}]
if {![file exists $xpr]} { source [file join $dir scripts create_project.tcl] } else { open_project $xpr }

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synth_1 failed" }
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "impl_1 failed" }

open_run impl_1
report_timing_summary -file [file join $dir build timing_summary.rpt]
report_utilization    -file [file join $dir build utilization.rpt]
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $impl_dir echo_top.bit] [file join $dir build echo.bit]
file copy -force [file join $impl_dir echo_top.ltx] [file join $dir build echo.ltx]
puts "Bitstream: [file join $dir build echo.bit]"
