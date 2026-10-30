# Rebuild the PYNQ-Z2 ECG project after extracting pulsecore_project.zip.
# Usage from the repository root:
#   vivado -mode batch -source build/rebuild.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set project_dir [file join $script_dir project_1]
set project_file [file join $project_dir project_1.xpr]

if {![file exists $project_file]} {
    error "Project not found. Extract build/pulsecore_project.zip so that build/project_1/project_1.xpr exists."
}

open_project $project_file

set bd_files [get_files -quiet *ecg_bd.bd]
if {[llength $bd_files] == 0} {
    error "ecg_bd.bd was not found in the project."
}

generate_target all $bd_files
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis did not complete successfully."
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation did not complete successfully."
}

open_run impl_1
report_utilization -file [file join $script_dir util.rpt]
report_timing_summary -file [file join $script_dir timing.rpt]

set bit_file [get_property DIRECTORY [get_runs impl_1]]
set bit_file [file join $bit_file ecg_bd_wrapper.bit]
set hwh_file [file join $project_dir project_1.gen sources_1 bd ecg_bd hw_handoff ecg_bd.hwh]

if {![file exists $bit_file]} {
    error "Generated bitstream not found: $bit_file"
}
if {![file exists $hwh_file]} {
    error "Generated HWH not found: $hwh_file"
}

set board_dir [file join $repo_dir board]
if {![file isdirectory $board_dir]} {
    error "Board output directory not found: $board_dir"
}
file copy -force $bit_file [file join $board_dir ecg_bd_wrapper.bit]
file copy -force $hwh_file [file join $board_dir ecg_bd_wrapper.hwh]

puts "Rebuild complete."
puts "Bitstream copied to: [file join $board_dir ecg_bd_wrapper.bit]"
puts "Hardware handoff copied to: [file join $board_dir ecg_bd_wrapper.hwh]"
close_project
