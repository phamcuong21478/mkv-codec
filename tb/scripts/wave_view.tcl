# Waveform layout for the xsim GUI, used by `make gui` (live run) and
# `make wave` (saved wave.wdb). Groups the signals that show one KAT:
# test markers, CPU register bus, input stream, output stream, core status.
set tb /tb_mkv_kat

proc grp {name} { return [add_wave_group $name] }

set g [grp "Test"]
add_wave -into $g -radix ascii    $tb/tb_phase
add_wave -into $g -radix dec      $tb/tb_vec $tb/tb_blk
add_wave -into $g                 $tb/tb_mode
add_wave -into $g -radix hex      $tb/tb_expect
add_wave -into $g -radix dec      $tb/cyc $tb/n_err

set g [grp "Clock / reset"]
add_wave -into $g $tb/clk $tb/rst_n

set g [grp "UPI register bus"]
add_wave -into $g                 $tb/upi_we $tb/upi_oe
add_wave -into $g -radix hex      $tb/upi_addr $tb/upi_din $tb/upi_dout

set g [grp "Input stream (din)"]
add_wave -into $g                 $tb/din_valid $tb/din_ready
add_wave -into $g -radix hex      $tb/din_data

set g [grp "Output stream (dout)"]
add_wave -into $g                 $tb/dout_valid $tb/dout_ready
add_wave -into $g -radix hex      $tb/dout_data

set g [grp "Core status"]
add_wave -into $g                 $tb/dut/core2reg_cfg_busy $tb/dut/reg2core_cfg_vld
