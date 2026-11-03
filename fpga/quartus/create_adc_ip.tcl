# Run with Quartus 21.1: qsys-script --script=create_adc_ip.tcl
package require -exact qsys 21.1
create_system audio_adc
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE 10M50DAF484C7G
add_instance adc altera_modular_dual_adc 21.1
set_instance_parameter_value adc CORE_VAR 3
set_instance_parameter_value adc sample_rate 0
set_instance_parameter_value adc clkdiv 2
set_instance_parameter_value adc refsel 0
set_instance_parameter_value adc refsel_adc2 0
set_instance_parameter_value adc use_ch1 true
set_instance_parameter_value adc use_ch9 true
set_instance_parameter_value adc enable_usr_sim 0
# ADC1 CH1 is the onboard Arduino A0 input. ADC2 is clocked in lockstep
# with a dummy CH0 conversion because the Dual ADC core synchronizes both.
foreach {name type direction source} {
    clock clock sink adc.clock
    reset reset sink adc.reset_sink
    pll_clock clock sink adc.adc_pll_clock
    pll_locked conduit end adc.adc_pll_locked
    command avalon_streaming sink adc.command
    command_2 avalon_streaming sink adc.command_2
    response avalon_streaming source adc.response
    response_2 avalon_streaming source adc.response_2
} {
    add_interface $name $type $direction
    set_interface_property $name EXPORT_OF $source
}
save_system audio_adc.qsys
