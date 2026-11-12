# xsim batch run with waveform dump. Called by the Makefile:
#   xsim <snapshot> -tclbatch xsim_run.tcl -wdb wave.wdb
# TB_WAVE (environment): wdb | vcd | both | none
set wave [expr {[info exists ::env(TB_WAVE)] ? $::env(TB_WAVE) : "wdb"}]

if {$wave eq "wdb" || $wave eq "both"} {
    # every signal of the hierarchy goes to wave.wdb (open it with `make wave`)
    log_wave -recursive *
}
if {$wave eq "vcd" || $wave eq "both"} {
    open_vcd wave.vcd
    log_vcd [get_objects -recursive /tb_mkv_kat/*]
}

run all

if {$wave eq "vcd" || $wave eq "both"} {
    flush_vcd
    close_vcd
}
quit
