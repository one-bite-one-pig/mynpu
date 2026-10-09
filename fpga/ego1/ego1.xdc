# EGo1 V2.2 / XC7A35T-1CSG324C pin skeleton.
# Confirm reset polarity and the exact board revision against the supplied
# schematic before programming hardware.
set_property PACKAGE_PIN P17 [get_ports sys_clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_i]
create_clock -name sys_clk -period 10.000 [get_ports sys_clk_i]

set_property PACKAGE_PIN P15 [get_ports reset_i]
set_property IOSTANDARD LVCMOS33 [get_ports reset_i]

set_property PACKAGE_PIN K3 [get_ports {led_o[0]}]
set_property PACKAGE_PIN M1 [get_ports {led_o[1]}]
set_property PACKAGE_PIN L1 [get_ports {led_o[2]}]
set_property PACKAGE_PIN K6 [get_ports {led_o[3]}]
set_property PACKAGE_PIN J5 [get_ports {led_o[4]}]
set_property PACKAGE_PIN H5 [get_ports {led_o[5]}]
set_property PACKAGE_PIN H6 [get_ports {led_o[6]}]
set_property PACKAGE_PIN K1 [get_ports {led_o[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[*]}]
