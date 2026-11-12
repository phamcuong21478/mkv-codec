`default_nettype none

// vb_mkv_round_a256 : engine-A256 2-cycle round datapath, MKV-256 (4 x 64-bit sub-states), V2 "A256-J"
//   (arch sections 15.5 / 15.6 / 15.15.2, ddoc/vb_mkv_round_a256_req.md). Pure datapath (LSN-4), R not reset.
//   One 256-bit state register R (the S-box input); cycle a: R <- M8(S(R)) ^ k, cycle b: R <- XW(S(R)) ^ k.
//   J-domain decryption (Q3): the decryption state is held as J(R) (J = byte reversal inside each 64-bit
//   sub-state), u = S^-1(R) ^ J(k), R <- ph ? XW(u) : M8(u): because M8^-1 = J*M8*J and J commutes with S^-1,
//   XW and xor, ONE forward M8 network (4 x vb_mkv_lin_m8) serves both directions; J on the load / key / result
//   is wiring. Lanes: vb_mkv_sbox_logic (reused unmodified), 32 S (DIR "ENC") and / or 32 S^-1 (DIR "DEC",
//   ENA_FWD 0), separate lanes (V2b shared lanes not used). DIR = "DEC" + ENA_FWD = 1 (INT): the forward arm
//   only runs F0 during key setup (k[255:5] = 0) and res is always the decryption form (engine A T6-A).
//   Instantiated by vb_mkv_eng_a256 as g_rnd_j.iround (DEC_ARCH = "JDOM" and every DIR = "ENC" build); the V1
//   alternative vb_mkv_round_a256s has the identical port / parameter list. Research source (logic unchanged):
//   research/mkv256_engines/v2/vb_mkv_round_a256.v.
module vb_mkv_round_a256 #(
    parameter DIR     = "BOTH",         //! "ENC": forward arm only | "DEC" / "BOTH": forward + inverse arms
    parameter ENA_FWD = 1,              //! 0: inverse arm only (DIR = "DEC" + KEY_SCHED = "EXT"); ignored for "ENC"
    parameter LD_FORM = "POST"          //! decryption load form: "POST" (EXT) | "PRE" (INT), as vb_mkv_round_a
) (
    input  wire         clk,            //! clock
    input  wire         en,             //! state enable, 0 holds R
    input  wire         ld,             //! load R from the load path
    input  wire         ph,             //! 0 = cycle a (S -> linear), 1 = cycle b (S -> XW)
    input  wire         dec,            //! inverse forms; registered by the parent, 0 during key setup
    input  wire         ld_xw,          //! load path applies the decryption form (XW and J)
    input  wire [255:0] ld_src,         //! load source (input block / key-setup chain input)
    input  wire [255:0] ld_key,         //! load key (whitening key / counter term)
    input  wire [255:0] k,              //! raw key of this cycle (store read data / counter term / 0)
    output wire [255:0] r_q,            //! state register R (J(R) while decrypting)
    output wire [255:0] r_xw,           //! XW(S(R)), forward, no key (F0 output); defined while dec = 0; 0 if ENA_FWD = 0
    output wire [255:0] res             //! result candidate: enc XW(S(R)) ^ k, dec J(S^-1(R) ^ J(k)) (normal domain)
);
    /* verilator lint_off WIDTHEXPAND */
    localparam HAS_INV = (DIR != "ENC") ? 1 : 0;
    localparam HAS_FWD = ((DIR == "ENC") || (ENA_FWD != 0)) ? 1 : 0;
    localparam LD_PRE  = (LD_FORM == "PRE") ? 1 : 0;
    localparam FWD_KS  = (DIR == "DEC") ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */

    function [255:0] f_xw;                       // XWords on 64-bit sub-states
        input [255:0] x;
        reg   [63:0]  sx;
        begin
            sx   = x[255:192] ^ x[191:128] ^ x[127:64] ^ x[63:0];
            f_xw = x ^ {sx, sx, sx, sx};
        end
    endfunction

    function [255:0] f_j;                        // J: byte reversal inside every 64-bit sub-state
        input [255:0] x;
        integer c, b;
        begin
            for (c = 0; c < 4; c = c + 1)
                for (b = 0; b < 8; b = b + 1)
                    f_j[255 - 64*c - 8*b -: 8] = x[255 - 64*c - 8*(7-b) -: 8];
        end
    endfunction

    reg  [255:0] r_ff;
    wire [255:0] nxt_run;
    wire [255:0] xw_q;
    genvar gi;
    generate
        if ((HAS_FWD != 0) && (HAS_INV == 0)) begin : g_enc
            wire [255:0] sf, lf;
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_sf
                vb_mkv_sbox_logic #(.DIR("ENC"), .ENA_FWD(1)) isf (.x(r_ff[8*gi +: 8]), .inv(1'b0), .y(sf[8*gi +: 8]));
            end
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_lf
                vb_mkv_lin_m8 ilf (.x(sf[255-64*gi -: 64]), .y(lf[255-64*gi -: 64]));
            end
            assign xw_q    = f_xw(sf);
            assign nxt_run = (ph ? xw_q : lf) ^ k;
            assign res     = xw_q ^ k;
            assign r_xw    = xw_q;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_dec = dec;
            /* verilator lint_on UNUSEDSIGNAL */
        end else if (HAS_FWD == 0) begin : g_inv_only
            wire [255:0] si, ui, li;
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_si
                vb_mkv_sbox_logic #(.DIR("DEC"), .ENA_FWD(0)) isi (.x(r_ff[8*gi +: 8]), .inv(1'b1), .y(si[8*gi +: 8]));
            end
            assign ui = si ^ f_j(k);
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_li
                vb_mkv_lin_m8 ili (.x(ui[255-64*gi -: 64]), .y(li[255-64*gi -: 64]));
            end
            assign xw_q    = f_xw(ui);
            assign nxt_run = ph ? xw_q : li;
            assign res     = f_j(ui);
            assign r_xw    = 256'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_dec = dec;
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_both
            wire [255:0] sf, si, ui, m, lm;
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_sf
                vb_mkv_sbox_logic #(.DIR("ENC"), .ENA_FWD(1)) isf (.x(r_ff[8*gi +: 8]), .inv(1'b0), .y(sf[8*gi +: 8]));
            end
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_si
                vb_mkv_sbox_logic #(.DIR("DEC"), .ENA_FWD(0)) isi (.x(r_ff[8*gi +: 8]), .inv(1'b1), .y(si[8*gi +: 8]));
            end
            assign ui = si ^ f_j(k);
            assign m  = dec ? ui : sf;
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_lm
                vb_mkv_lin_m8 ilm (.x(m[255-64*gi -: 64]), .y(lm[255-64*gi -: 64]));
            end
            wire [255:0] kf = (FWD_KS != 0) ? {251'd0, k[4:0]} : k;
            assign xw_q    = f_xw(m);
            assign nxt_run = (ph ? xw_q : lm) ^ (dec ? 256'd0 : kf);
            assign res     = (FWD_KS != 0) ? f_j(ui) : (dec ? f_j(ui) : (xw_q ^ k));
            assign r_xw    = xw_q;
        end
    endgenerate

    // load: decryption loads J(XW(...)) (PRE: XW(src ^ key); POST: XW(src) ^ key)
    wire         ldx  = (HAS_INV != 0) && ld_xw;
    wire [255:0] ld_d = (LD_PRE != 0) ? (ldx ? f_j(f_xw(ld_src ^ ld_key)) : (ld_src ^ ld_key))
                                      : (ldx ? f_j(f_xw(ld_src) ^ ld_key) : (ld_src ^ ld_key));

    always @(posedge clk) begin
        if (en) begin
            r_ff <= ld ? ld_d : nxt_run;
        end
    end
    assign r_q = r_ff;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_ok = ld_xw;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
