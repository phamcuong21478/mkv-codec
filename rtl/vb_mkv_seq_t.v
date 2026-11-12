`default_nettype none

// vb_mkv_seq_t : engine-T block sequencer (vb_mkv_eng_t, arch v4 section 14.2/14.6)
//   2-cycle round: phase A (T lookup) / phase B (XW lookup). Cycle classes:
//     LC (load-capable): idle, or the cycle after the last B of a block (output capture, outp_ff = 1).
//         A transfer (din_valid & din_ready) in LC is phase A of round 0 of the new block (address = ldv ^ wk).
//     B(r): address = XOR4 ^ K1_r; A(r), r >= 1: address = XOR4 ^ K0_r.
//   Timing: transfer cycle t (A of round 0), B(R-1) in t+2R-1, capture in LC t+2R, dout_valid at t+2R+1
//   (latency 2R+1); the capture cycle is the next block's transfer cycle (interval 2R).
//   Store read address (rdata appears the next cycle, engine-private index = consumption order):
//     LC: transfer ? 2 : 1   A(r): 2r+2   B(r): last ? 1 : 2r+3   -> kt_ff <= rk every cycle.
//   Back-pressure (A-8): stall = outp_ff & dout_valid (registered terms only); din_ready has no din_valid /
//   dout_ready term.
module vb_mkv_seq_t #(
    parameter RS_LV = 0                 //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configuration (vb_mkv_cfg)
    input  wire         cfg_vld,        //! request strobe (blocks transfers in its cycle)
    input  wire         key_valid,      //! key loaded (C_READY)
    input  wire         act_mode,       //! 0 encrypt, 1 decrypt (DIR-forced)
    input  wire         mode_nx,        //! mode of the next cycle (= act_mode, or the new mode in the kx_done cycle)
    input  wire [3:0]   act_rnd,        //! R of the loaded key

    // stream
    input  wire         din_valid,      //! input block valid
    output wire         din_ready,      //! transfer allowed this cycle
    output wire         dout_valid,     //! output block valid (registered)
    input  wire         dout_ready,     //! sink ready

    // engine
    output wire         eng_idle,       //! no block in flight and no pending capture (vb_mkv_cfg)
    output wire         ld_dec,         //! load value XW(din) (decryption)
    output wire         dout_dec,       //! output XW(XOR4) ^ kp (decryption)

    // datapath controls (round_t): next-cycle lookup controls, current-cycle enables
    output wire         gate_nx,        //! next cycle: address = XOR4 ^ kt_eff
    output wire [1:0]   asel_nx,        //! next cycle: kt_eff source (0 kt_ff, 1 ldv ^ wk)
    output wire [1:0]   hs_nx,          //! next cycle: table half
    output wire         ben,            //! BRAM read enable this cycle
    output wire         dout_ce,        //! output capture this cycle
    output wire [4:0]   raddr           //! store read address this cycle
);

    localparam RS_ACT = (RS_LV != 0) ? 1'b1 : 1'b0;
    localparam S_LC   = 2'd0;           // load-capable (idle / capture)
    localparam S_A    = 2'd1;           // phase A, rounds 1..R-1
    localparam S_B    = 2'd2;           // phase B

    reg  [1:0]   st_ff;
    reg  [3:0]   r_ff;
    reg          outp_ff;               // this LC cycle captures the output of the previous block
    reg          dv_ff;

    wire         st_lc   = (st_ff == S_LC);
    wire         st_a    = (st_ff == S_A);
    wire         st_b    = (st_ff == S_B);
    wire         last_r  = (r_ff == (act_rnd - 4'd1));
    wire         stall   = outp_ff & dv_ff;                       // registered-only back-pressure
    wire         can_acc = key_valid & ~cfg_vld & st_lc & ~stall;
    wire         accept  = can_acc & din_valid;

    reg  [1:0]   st_nx;
    always @* begin
        case (st_ff)
            S_LC   : st_nx = accept ? S_B : S_LC;
            S_A    : st_nx = S_B;
            S_B    : st_nx = last_r ? S_LC : S_A;
            default: st_nx = S_LC;
        endcase // st_ff
    end
    wire [3:0]   r_nx    = accept ? 4'd0 : (st_b & ~last_r) ? (r_ff + 4'd1) : r_ff;
    wire         outp_nx = (st_b & last_r) | (outp_ff & stall);

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            st_ff   <= S_LC;
            r_ff    <= 4'd0;
            outp_ff <= 1'b0;
            dv_ff   <= 1'b0;
        end else begin
            st_ff   <= st_nx;
            r_ff    <= r_nx;
            outp_ff <= outp_nx;
            dv_ff   <= dout_ce | (dv_ff & ~dout_ready);
        end
    end

    //==========================================================================
    // datapath controls
    //==========================================================================

    assign gate_nx  = (st_nx != S_LC);
    assign asel_nx  = (st_nx == S_LC) ? 2'd1 : 2'd0;
    assign hs_nx    = {mode_nx, (st_nx == S_B)};                // ENC 0/1, DEC 2/3 (mode valid next cycle)
    assign ben      = st_a | st_b | accept;
    assign dout_ce  = outp_ff & ~stall;
    assign raddr    = st_lc ? (accept ? 5'd2 : 5'd1)
                    : st_a  ? {r_ff, 1'b0} + 5'd2
                    :         (last_r ? 5'd1 : ({r_ff, 1'b0} + 5'd3))
                    ;

    assign din_ready  = can_acc;
    assign dout_valid = dv_ff;
    assign eng_idle   = st_lc & ~outp_ff;
    assign ld_dec     = act_mode;
    assign dout_dec   = act_mode;

endmodule

`default_nettype wire
