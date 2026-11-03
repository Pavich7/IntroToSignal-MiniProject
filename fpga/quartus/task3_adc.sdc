create_clock -name clk_50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_pll_clocks
derive_clock_uncertainty
# Asynchronous reset input and human/scope-only observation outputs.
set_false_path -from [get_ports {KEY[0]}]
set_false_path -to [get_ports {LEDR[*] GPIO[0] GPIO[1] GPIO[5]}]
# SPI/ACK are asynchronous. Only the paths TO the first synchronizer flop are cut.
set_false_path -from [get_ports {GPIO[2]}] -to [get_registers {*sender*sclk_sync[0]}]
set_false_path -from [get_ports {GPIO[4]}] -to [get_registers {*sender*cs_sync[0]}]
set_false_path -from [get_ports {GPIO[6]}] -to [get_registers {*sender*ack_sync[0]}]
# Mode-0 MISO changes after the synchronized falling edge of 1 MHz SCLK.
# 100 ns output path budget leaves >300 ns of the 500 ns half-period for setup.
set_max_delay 100.0 -to [get_ports {GPIO[3]}]
set_min_delay 0.0 -to [get_ports {GPIO[3]}]
