//==============================================================================
// Function     : vb_icg - integrated clock gate (latch + AND), ASIC helper of vb_sdp_ram_pp
//   gclk = clk & en_l, en_l = (en | se) captured by a latch transparent while clk is low
//   (glitch-free; same function as a library "latch_posedge_precontrol" ICG).
//   Library hook: define VB_ICG_NANGATE45 (Nangate45 CLKGATETST_X1) or VB_ICG_CELL=<module>
//   (ports CK, E, SE, GCK) to drop in the foundry ICG instead of the behavioural model.
//==============================================================================
`default_nettype none

module vb_icg (
    input  wire clk,        //! clock
    input  wire en,         //! functional enable (sampled while clk is low)
    input  wire se,         //! scan / test enable (forces the clock on)
    output wire gclk        //! gated clock
);

`ifdef VB_ICG_NANGATE45
    CLKGATETST_X1 icg (.CK(clk), .E(en), .SE(se), .GCK(gclk));
`elsif VB_ICG_CELL
    `VB_ICG_CELL icg (.CK(clk), .E(en), .SE(se), .GCK(gclk));
`else
    reg en_l;
    /* verilator lint_off LATCH */
    always @(*) begin
        if (!clk)
            en_l = en | se;     // intentional latch: transparent while clk is low
    end
    /* verilator lint_on LATCH */
    assign gclk = clk & en_l;
`endif

endmodule // vb_icg

`default_nettype wire
