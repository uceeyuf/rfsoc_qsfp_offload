# Create the Vivado project of the UDP echo (tested with Vivado 2023.2).
#
#   make build_ip                   (repository root, once: the network layer IP)
#   vivado -mode batch -source scripts/create_project.tcl
#
# The project is created in build/ next to this directory's sources.

set dir       [file normalize [file join [file dirname [info script]] ..]]
set proj_name qsfp_udp_echo
set proj_dir  [file join $dir build $proj_name]

create_project $proj_name $proj_dir -part xczu48dr-ffvg1517-2-e -force
set_property target_language Verilog [current_project]
set_property ip_repo_paths [file normalize [file join $dir .. .. ip_repo xup_vitis_network_example NetLayers]] [current_project]
update_ip_catalog

set ve [file join $dir third_party verilog-ethernet]
add_files -norecurse -fileset sources_1 [concat \
    [glob [file join $dir rtl *.v]] \
    [file join $ve lib axis rtl axis_fifo.v] \
    [file join $ve lib axis rtl sync_reset.v]]
foreach ip_tcl [glob [file join $dir ip *.tcl]] { source $ip_tcl }
set_property top echo_top [get_filesets sources_1]

add_files -norecurse -fileset constrs_1 [file join $dir constraints echo.xdc]
set f [file join $ve lib axis syn vivado sync_reset.tcl]
add_files -norecurse -fileset constrs_1 $f
set_property file_type TCL [get_files $f]
set_property used_in_synthesis false [get_files $f]
set_property processing_order LATE [get_files $f]

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
update_compile_order -fileset sources_1
generate_target all [get_ips]
puts "Project created: [file join $proj_dir $proj_name.xpr]"
