`default_nettype none

// vb_mkv_round_a256s : engine-A256 2-cycle round datapath, MKV-256 (4 x 64-bit sub-states), V1 "A256-sep"
//   (arch section 15.15.2, ddoc/vb_mkv_round_a256s_req.md). Pure datapath (LSN-4), R not reset.
//   The engine-A-128 decryption structure at 256 bits: decryption in the raw domain, u = S^-1(R) ^ k,
//   R <- ph ? XW(u) : M8^-1(u) with a separate inverse network (4 x vb_mkv_lin_m8i = J*M8*J wiring around
//   vb_mkv_lin_m8), forward arm 4 x vb_mkv_lin_m8, arm mux after the linear layers. Same ports, parameters,
//   cycle behaviour and engine-visible results as vb_mkv_round_a256 (state R here, J(R) there while
//   decrypting). DIR in {"DEC", "BOTH"} only: vb_mkv_eng_a256 never instantiates it for ENC, and an ENC value
//   instantiates the undefined module vb_mkv_round_a256s_illegal_DIR (elaboration guard).
//   Instantiated by vb_mkv_eng_a256 as g_rnd_s.iround (DEC_ARCH = "SEP", DIR != "ENC"). Research source
//   (module renamed, ENC branch replaced by the guard, logic otherwise unchanged):
//   research/mkv256_engines/v1/vb_mkv_round_a256.v.
module vb_mkv_round_a256s #(
    parameter DIR     = "BOTH",         //! "DEC" / "BOTH" (forward + inverse arms); "ENC" = elaboration error
    parameter ENA_FWD = 1,              //! 0: inverse arm only (DIR = "DEC" + KEY_SCHED = "EXT")
    parameter LD_FORM = "POST"          //! decryption load form: "POST" (EXT) | "PRE" (INT), as vb_mkv_round_a
) (
    input  wire         clk,            //! clock
    input  wire         en,             //! state enable, 0 holds R
    input  wire         ld,             //! load R from the load path
    input  wire         ph,             //! 0 = cycle a (S -> linear), 1 = cycle b (S -> XW)
    input  wire         dec,            //! inverse forms; registered by the parent, 0 during key setup
    input  wire         ld_xw,          //! load path applies the decryption form (XW)
    input  wire [255:0] ld_src,         //! load source (input block / key-setup chain input)
    input  wire [255:0] ld_key,         //! load key (whitening key / counter term)
    input  wire [255:0] k,              //! raw key of this cycle (store read data / counter term / 0)
    output wire [255:0] r_q,            //! state register R (raw domain in both directions)
    output wire [255:0] r_xw,           //! XW(S(R)), forward, no key (F0 output); defined while dec = 0; 0 if ENA_FWD = 0
    output wire [255:0] res             //! result candidate: enc XW(S(R)) ^ k, dec S^-1(R) ^ k
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

    reg  [255:0] r_ff;
    wire [255:0] nxt_run;
    wire [255:0] xw_q;
    genvar gi;
    generate
        if (HAS_INV == 0) begin : g_illegal_dir
            // DIR = "ENC" is not supported (the engine uses vb_mkv_round_a256): undefined module = elaboration error
            vb_mkv_round_a256s_illegal_DIR u_illegal_dir ();
            assign xw_q    = 256'd0;
            assign nxt_run = r_ff;
            assign res     = 256'd0;
            assign r_xw    = 256'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_enc = dec | (|k);
            /* verilator lint_on UNUSEDSIGNAL */
        end else if (HAS_FWD == 0) begin : g_inv_only
            wire [255:0] si, ui, li;
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_si
                vb_mkv_sbox_logic #(.DIR("DEC"), .ENA_FWD(0)) isi (.x(r_ff[8*gi +: 8]), .inv(1'b1), .y(si[8*gi +: 8]));
            end
            assign ui = si ^ k;
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_li
                vb_mkv_lin_m8i ili (.x(ui[255-64*gi -: 64]), .y(li[255-64*gi -: 64]));
            end
            assign xw_q    = f_xw(ui);
            assign nxt_run = ph ? xw_q : li;
            assign res     = ui;
            assign r_xw    = 256'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_dec = dec;
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_both
            wire [255:0] sf, si, ui, lf, li;
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_sf
                vb_mkv_sbox_logic #(.DIR("ENC"), .ENA_FWD(1)) isf (.x(r_ff[8*gi +: 8]), .inv(1'b0), .y(sf[8*gi +: 8]));
            end
            for (gi = 0; gi < 32; gi = gi + 1) begin : gen_si
                vb_mkv_sbox_logic #(.DIR("DEC"), .ENA_FWD(0)) isi (.x(r_ff[8*gi +: 8]), .inv(1'b1), .y(si[8*gi +: 8]));
            end
            assign ui = si ^ k;
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_lf
                vb_mkv_lin_m8 ilf (.x(sf[255-64*gi -: 64]), .y(lf[255-64*gi -: 64]));
            end
            for (gi = 0; gi < 4; gi = gi + 1) begin : gen_li
                vb_mkv_lin_m8i ili (.x(ui[255-64*gi -: 64]), .y(li[255-64*gi -: 64]));
            end
            wire [255:0] kf = (FWD_KS != 0) ? {251'd0, k[4:0]} : k;
            assign xw_q    = f_xw(dec ? ui : sf);
            assign nxt_run = dec ? (ph ? xw_q : li) : ((ph ? xw_q : lf) ^ kf);
            assign res     = (FWD_KS != 0) ? ui : (dec ? ui : (xw_q ^ k));
            assign r_xw    = xw_q;
        end
    endgenerate

    wire [255:0] ld_v = (LD_PRE != 0) ? (ld_src ^ ld_key) : ld_src;
    wire [255:0] ld_w = ((HAS_INV != 0) && ld_xw) ? f_xw(ld_v) : ld_v;
    wire [255:0] ld_d = (LD_PRE != 0) ? ld_w : (ld_w ^ ld_key);

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
