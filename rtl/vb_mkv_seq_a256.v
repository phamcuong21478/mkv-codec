`default_nettype none

// vb_mkv_seq_a256 : engine-A256 block sequencer (arch sections 15.6 / 15.15, ddoc/vb_mkv_seq_a256_req.md)
//   vb_mkv_seq_a behaviour with a 256-bit output register (A-32: vb_mkv_seq_a is not modified).
//   2-phase round: a block is the load cycle (overlapping the last cycle of the previous block) plus
//   cycles c = 1 .. 2R (odd = a, even = b); interval exactly 2R, latency exactly 2R+1. Stream handshake
//   with registered-only back-pressure (A-8): the engine stalls only in the last cycle while dout_valid is
//   high; no dout_ready -> din_ready path. Round-key store read address issued one cycle before use:
//   enc index c, dec index 2R - c (raw v3 store map, the decryption key XOR sits before the linear layer).
//   Output register dout_ff. research/mkv256_engines/rtl/vb_mkv_seq_a256.v (widened a_core_int.v a_ctl)
module vb_mkv_seq_a256 #(
    parameter DIR   = "BOTH",           //! "ENC" -> enc addressing, else act_mode (DIR-forced by vb_mkv_cfg)
    parameter RS_LV = 0                 //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configuration (vb_mkv_cfg)
    input  wire         key_valid,      //! a key is loaded (C_READY)
    input  wire         cfg_vld,        //! request pulse: no block accepted in this cycle
    input  wire         act_mode,       //! active mode (1 = decrypt), DIR-forced by vb_mkv_cfg
    input  wire [3:0]   act_rnd,        //! active R
    output wire         eng_idle,       //! no block in flight (an output held in dout_ff may remain)

    // input block stream
    input  wire         din_valid,      //! input block valid
    output wire         din_ready,      //! = key_valid & !cfg_vld & slot_free

    // output block stream
    output wire         dout_valid,     //! registered
    input  wire         dout_ready,     //! sink ready
    output wire [255:0] dout_data,      //! registered

    // round datapath (vb_mkv_round_a256 / vb_mkv_round_a256s)
    input  wire [255:0] r_res,          //! result candidate, captured in the completing last cycle
    output wire         blk_en,         //! state enable
    output wire         blk_ld,         //! load the accepted block this cycle
    output wire         blk_ph,         //! 0 = cycle a, 1 = cycle b

    // round-key store read port (1-cycle registered read)
    output wire         mrk_ld,         //! read enable, 0 holds the read data (stall)
    output wire [4:0]   mrk_raddr       //! key index of the next cycle
);

    /* verilator lint_off WIDTHEXPAND */
    localparam DIR_ENC = (DIR == "ENC") ? 1'b1 : 1'b0;
    /* verilator lint_on WIDTHEXPAND */
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;  // 1-bit reset level

    //==========================================================================
    // storage
    //==========================================================================

    reg          run_ff;                // a block is in flight
    reg  [4:0]   cyc_ff;                // cycle index c = 1 .. 2R of the block in flight
    reg          dv_ff;                 // output register valid
    reg  [255:0] dout_ff;               // output register (datapath, qualified by dv_ff: no reset)

    //==========================================================================
    // block timing and handshake
    //==========================================================================

    // direction from the active (DIR-forced) mode of vb_mkv_cfg, as v3: act_mode = 0 / act_rnd = 0 until the
    // first key, so the idle read index stays 1 (in range); DIR = "DEC" -> act_mode = 1 after every load (vtrace T-7)
    wire         dec       = DIR_ENC ? 1'b0 : act_mode;
    wire [4:0]   two_r     = {act_rnd, 1'b0};
    wire         last      = run_ff && (cyc_ff == two_r);
    wire         stall     = last && dv_ff;                 // previous result not yet taken
    wire         complete  = last && (!dv_ff);
    wire         slot_free = (!run_ff) || complete;
    wire         acc       = din_valid && din_ready;

    assign din_ready = key_valid && (!cfg_vld) && slot_free;

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            run_ff <= 1'b0;
            cyc_ff <= 5'd0;
        end else if (acc) begin
            run_ff <= 1'b1;
            cyc_ff <= 5'd1;
        end else if (complete) begin
            run_ff <= 1'b0;
        end else if (run_ff && (!last)) begin
            cyc_ff <= cyc_ff + 5'd1;
        end
    end

    //==========================================================================
    // output register
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            dv_ff <= 1'b0;
        end else if (complete) begin
            dv_ff <= 1'b1;
        end else if (dout_ready) begin
            dv_ff <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (complete) begin
            dout_ff <= r_res;
        end
    end

    //==========================================================================
    // store read address (one cycle ahead): next cycle c_n, enc c_n / dec 2R - c_n
    //==========================================================================

    wire [4:0]   cyc_nx = (run_ff && (!last)) ? (cyc_ff + 5'd1) : 5'd1;

    assign mrk_ld    = !stall;
    assign mrk_raddr = dec ? (two_r - cyc_nx) : cyc_nx;

    //==========================================================================
    // outputs
    //==========================================================================

    assign eng_idle   = !run_ff;
    assign blk_en     = acc || (run_ff && (!stall));
    assign blk_ld     = acc;
    assign blk_ph     = !cyc_ff[0];
    assign dout_valid = dv_ff;
    assign dout_data  = dout_ff;

endmodule

`default_nettype wire
