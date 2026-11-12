`default_nettype none

// vb_mkv_round_a : engine-A 2-cycle MKV-128 round datapath (arch v4 section 14.2, REQ-V4-2)
//   One 128-bit state register R (the S-box input), raw round keys, S-box layer used every cycle:
//     cycle a (ph = 0): enc / key setup R <= M4(S(R)) ^ k        dec R <= M4^-1(S^-1(R) ^ k)
//     cycle b (ph = 1): enc / key setup R <= XW(S(R)) ^ k        dec R <= XW(S^-1(R) ^ k)
//     load    (ld = 1): R <= LD_FORM "POST": (ld_xw ? XW(ld_src) : ld_src) ^ ld_key
//                                    "PRE" : ld_xw ? XW(ld_src ^ ld_key) : ld_src ^ ld_key
//     result  res     = enc XW(S(R)) ^ k (K_post), dec S^-1(R) ^ k (K_0^0), valid in the last b cycle
//     r_xw            = XW(S(R)) forward, no key = F0 output for the key schedule (dec = 0)
//   Lanes: vb_mkv_sbox_logic, separate S (fom_s) / S^-1 (fom_si) lanes; linear layer vb_mkv_lin_slp.
//   Pure datapath (LSN-4): no FSM, no round index, keys through ports. research/arch_a_asic/int/a_round_int.v
module vb_mkv_round_a #(
    parameter DIR     = "BOTH",         //! "ENC": forward arm only; "DEC" | "BOTH": forward + inverse arms
    parameter ENA_FWD = 1,              //! 0: inverse arm only (DIR = "DEC" + KEY_SCHED = "EXT", REQ-V3-3)
    parameter LD_FORM = "POST"          //! load whitening form: "POST" (EXT, wk = XW(K_post)) | "PRE" (INT, raw)
) (
    input  wire         clk,            //! clock
    input  wire         en,             //! state enable, 0 holds R
    input  wire         ld,             //! load the state from the load path
    input  wire         ph,             //! 0 = cycle a (S -> M4 / M4^-1), 1 = cycle b (S -> XW)
    input  wire         dec,            //! inverse forms (registered, quasi-static; 0 during key setup)
    input  wire         ld_xw,          //! load path applies XW (decryption block load)
    input  wire [127:0] ld_src,         //! load source (input block / key-setup chain input)
    input  wire [127:0] ld_key,         //! load key (whitening key / key-setup counter term)
    input  wire [127:0] k,              //! key of this cycle (store read data / counter term / 0)
    output wire [127:0] r_q,            //! state register R
    output wire [127:0] r_xw,           //! forward XW(S(R)) (F0 output for the key schedule)
    output wire [127:0] res             //! result candidate (captured in the last b cycle)
);

    /* verilator lint_off WIDTHEXPAND */
    localparam HAS_INV = (DIR != "ENC") ? 1 : 0;        // inverse arm present
    localparam HAS_FWD = ((DIR == "ENC") || (ENA_FWD != 0)) ? 1 : 0;   // forward arm present
    localparam LD_PRE  = (LD_FORM == "PRE") ? 1 : 0;    // key before the load XW
    localparam FWD_KS  = (DIR == "DEC") ? 1 : 0;        // DEC (INT): forward arm runs F0 only (voptimize T6-A)
    /* verilator lint_on WIDTHEXPAND */

    //==========================================================================
    // XWords: y^i = x^i ^ (x^0 ^ x^1 ^ x^2 ^ x^3), 32-bit sub-states
    //==========================================================================

    function [127:0] f_xw;
        input [127:0] x;
        reg   [31:0]  sx;
        begin
            sx   = x[127:96] ^ x[95:64] ^ x[63:32] ^ x[31:0];
            f_xw = x ^ {sx, sx, sx, sx};
        end
    endfunction

    //==========================================================================
    // state register and arms
    //==========================================================================

    reg  [127:0] r_ff;                  // state R = S-box input, no reset (datapath, LSN-8)
    wire [127:0] nxt_run;               // next state of a round cycle
    wire [127:0] xw_q;                  // XW of the active arm (forward S, or S^-1 ^ k)

    genvar gi;

    generate
        if ((HAS_FWD != 0) && (HAS_INV == 0)) begin : g_enc
            // ENC: forward arm only
            wire [127:0] sf;            // S(R)
            wire [127:0] lf;            // M4(S(R))
            for (gi = 0; gi < 16; gi = gi + 1) begin : gen_lane
                vb_mkv_sbox_logic #(
                    .DIR     ("ENC"),
                    .ENA_FWD (1)
                ) isf (
                    .x   (r_ff[8*gi +: 8]),
                    .inv (1'b0),
                    .y   (sf[8*gi +: 8])
                );
            end
            // column c = bits [127-32c -: 32] (element 0 in the MS byte)
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_col
                vb_mkv_lin_slp #(
                    .INV (0)
                ) im4 (
                    .x (sf[127-32*gi -: 32]),
                    .y (lf[127-32*gi -: 32])
                );
            end
            assign xw_q    = f_xw(sf);
            assign nxt_run = (ph ? xw_q : lf) ^ k;
            assign res     = xw_q ^ k;
            assign r_xw    = xw_q;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_dec = dec;
            /* verilator lint_on UNUSEDSIGNAL */
        end else if (HAS_FWD == 0) begin : g_inv_only
            // DEC + EXT: inverse arm only, every cycle a decryption cycle
            wire [127:0] si;            // S^-1(R)
            wire [127:0] ui;            // S^-1(R) ^ k (key before the linear layer)
            wire [127:0] li;            // M4^-1(ui)
            for (gi = 0; gi < 16; gi = gi + 1) begin : gen_lane
                vb_mkv_sbox_logic #(
                    .DIR     ("DEC"),
                    .ENA_FWD (0)
                ) isi (
                    .x   (r_ff[8*gi +: 8]),
                    .inv (1'b1),
                    .y   (si[8*gi +: 8])
                );
            end
            assign ui = si ^ k;
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_col
                vb_mkv_lin_slp #(
                    .INV (1)
                ) im4i (
                    .x (ui[127-32*gi -: 32]),
                    .y (li[127-32*gi -: 32])
                );
            end
            assign xw_q    = f_xw(ui);
            assign nxt_run = ph ? xw_q : li;
            assign res     = ui;
            assign r_xw    = 128'd0;    /* no forward arm, no key schedule */
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_dec = dec;
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_both
            // DEC (INT) / BOTH: separate forward and inverse arms, muxed once at the end (variant ii)
            wire [127:0] sf;            // S(R)
            wire [127:0] si;            // S^-1(R)
            wire [127:0] ui;            // S^-1(R) ^ k
            wire [127:0] lf;            // M4(S(R))
            wire [127:0] li;            // M4^-1(ui)
            for (gi = 0; gi < 16; gi = gi + 1) begin : gen_lane
                vb_mkv_sbox_logic #(
                    .DIR     ("ENC"),
                    .ENA_FWD (1)
                ) isf (
                    .x   (r_ff[8*gi +: 8]),
                    .inv (1'b0),
                    .y   (sf[8*gi +: 8])
                );
                vb_mkv_sbox_logic #(
                    .DIR     ("DEC"),
                    .ENA_FWD (0)
                ) isi (
                    .x   (r_ff[8*gi +: 8]),
                    .inv (1'b1),
                    .y   (si[8*gi +: 8])
                );
            end
            assign ui = si ^ k;
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_col
                vb_mkv_lin_slp #(
                    .INV (0)
                ) im4 (
                    .x (sf[127-32*gi -: 32]),
                    .y (lf[127-32*gi -: 32])
                );
                vb_mkv_lin_slp #(
                    .INV (1)
                ) im4i (
                    .x (ui[127-32*gi -: 32]),
                    .y (li[127-32*gi -: 32])
                );
            end
            // the b path is short: one XW after the arm mux
            // DIR = "DEC" (FWD_KS, voptimize T6-A): dec = 0 only during key setup, where k is the counter term
            // (bits [127:5] = 0) and no result is taken -> forward key XOR on 5 bits, res = the inverse form only
            wire [127:0] kf = (FWD_KS != 0) ? {123'd0, k[4:0]} : k;
            assign xw_q    = f_xw(dec ? ui : sf);
            assign nxt_run = dec ? (ph ? xw_q : li)
                                 : ((ph ? xw_q : lf) ^ kf)
                                 ;
            assign res     = (FWD_KS != 0) ? ui : (dec ? ui : (xw_q ^ k));
            assign r_xw    = xw_q;      /* = XW(S(R)) while dec = 0 */
        end
    endgenerate

    //==========================================================================
    // load path
    //==========================================================================

    wire [127:0] ld_v = (LD_PRE != 0) ? (ld_src ^ ld_key) : ld_src;
    wire [127:0] ld_w = ((HAS_INV != 0) && ld_xw) ? f_xw(ld_v) : ld_v;
    wire [127:0] ld_d = (LD_PRE != 0) ? ld_w : (ld_w ^ ld_key);

    always @(posedge clk) begin
        if (en) begin
            r_ff <= ld ? ld_d : nxt_run;
        end
    end

    assign r_q = r_ff;

    // ld_xw is meaningless without an inverse arm
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_ok = ld_xw;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
