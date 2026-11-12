`default_nettype none

// vb_mkv_kx_a256 : engine-A256 INT key schedule for MKV-256 (ALG-KS on n = 256, arch sections 15.6 / 15.15,
//   ddoc/vb_mkv_kx_a256_req.md). vb_mkv_kx_a algorithm and slot schedule at 256 bits (A-32: vb_mkv_kx_a is not
//   modified); K_int on 64-bit words, counter term in bits [4:0].
//   F0 (forward round, zero keys) runs on the 2-cycle datapath (vb_mkv_round_a256 / _a256s, dec = 0). UpdateKS i = 1..R
//   takes 8 slots s = 1..8 (odd = cycle a, even = cycle b):
//     L-chain  R = L_{i-1} ^ <2i-1>     loaded in INIT (i = 1) or by the s = 8 b-cycle of step i-1 (k = <2i-1>)
//              s = 1..4: F0(F0(.)); s = 4: G = XW(S(R)) -> store[2i] (parked), R <= R_{i-1} ^ <2i>
//     R-chain  s = 5..8: F0(F0(.)); s = 8: L_i = XW(S(R)), R_i = L_i ^ G (G read back at s = 7)
//                                    -> store[2i] = R_i, next cycle store[2i-1] = L_i (= R ^ k of s = 8)
//   No L / R state registers: L_0 / R_0 come from cfg_key combinationally (held by the vb_mkv_reg MK lock,
//   REQ-V4-8), R_{i-1} is read back from store[2i-2] at s = 3. Busy INIT + 8R + FIN = 8R+2 cycles.
//   Store map (raw keys, v3 / ARCH-6): K_0^0 = L_0 -> 0, L_i = K_{i-1}^1 -> 2i-1, R_i = K_i^0 / K_post -> 2i.
//   Whitening key: enc L_0 (INIT), dec raw K_post = R_R (round LD_FORM = "PRE").
//   research/mkv256_engines/rtl/vb_mkv_kx_a256.v (widened research/arch_a_asic/int/a_kx.v, KSST = "STORE")
module vb_mkv_kx_a256 #(
    parameter DIR     = "BOTH",         //! mode forcing: "ENC" -> 0, "DEC" -> 1, "BOTH" -> cfg_mode
    parameter PROFILE = "TCVN2024",     //! "TCVN2024" (R = 6/7/8) | "IETF2026" (R = 7/8/9)
    parameter RS_LV   = 0               //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port (mode / KLEN sampled at cfg_vld; cfg_key read combinationally while busy)
    input  wire         cfg_vld,        //! sample the request, abort a running setup
    input  wire         cfg_mode,       //! 0 = encrypt, 1 = decrypt
    input  wire [1:0]   cfg_klen,       //! 0/1/2 = 256/384/512 bit
    input  wire [511:0] cfg_key,        //! {MK0..MK15}, MK0 in [511:480], stable while busy (MK lock)

    // key source contract towards vb_mkv_cfg
    input  wire         kx_start,       //! begin the setup of the sampled request
    output wire         kx_busy,        //! setup running (INIT .. FIN)
    output wire         kx_done,        //! pulse in the last setup cycle (FIN)
    output wire         kx_mode,        //! sampled DIR-forced mode
    output wire [3:0]   kx_rnd,         //! sampled R
    output wire [255:0] kx_wk,          //! whitening key: L_0 (enc) / raw K_post (dec)

    // round datapath control while kx_busy (vb_mkv_round_a256 / vb_mkv_round_a256s)
    output wire         ks_ld,          //! load cycle (INIT, s = 4)
    output wire         ks_ph,          //! 0 = cycle a, 1 = cycle b
    output wire [255:0] ks_src,         //! load source: L_0 (INIT), R_{i-1} (s = 4)
    output wire [255:0] ks_kt,          //! counter term <n> (load key / s = 8 round key), else 0
    input  wire [255:0] r_xw,           //! F0 output XW(S(R))
    input  wire [255:0] r_q,            //! state register R

    // round-key store (lib vb_sdp_ram_pp, 1-cycle registered read)
    output wire         mrk_st,         //! write enable
    output wire [4:0]   mrk_waddr,      //! write index
    output wire [255:0] mrk_wdata,      //! write data
    output wire         mrk_ld,         //! read enable (s = 3, s = 7)
    output wire [4:0]   mrk_raddr,      //! read index
    input  wire [255:0] mrk_rdata       //! read data
);

    /* verilator lint_off WIDTHEXPAND */
    localparam IS_IETF = (PROFILE == "IETF2026") ? 1'b1 : 1'b0;
    localparam DIR_ENC = (DIR == "ENC") ? 1'b1 : 1'b0;
    localparam DIR_DEC = (DIR == "DEC") ? 1'b1 : 1'b0;
    /* verilator lint_on WIDTHEXPAND */
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;  // 1-bit reset level

    localparam [1:0] K_IDLE = 2'd0;     // no setup running
    localparam [1:0] K_INIT = 2'd1;     // R <= L_0 ^ <1>, store[0] <= L_0
    localparam [1:0] K_RUN  = 2'd2;     // UpdateKS slots
    localparam [1:0] K_FIN  = 2'd3;     // write L_R, last busy cycle (kx_done)

    //==========================================================================
    // functions
    //==========================================================================

    // R from the key-length code and PROFILE (KLEN = 3 is rejected by vb_mkv_cfg: don't care)
    function [3:0] f_rnd;
        input [1:0] klen;
        begin
            case (klen)
                2'd0:    f_rnd = IS_IETF ? 4'd7 : 4'd6;
                2'd1:    f_rnd = IS_IETF ? 4'd8 : 4'd7;
                2'd2:    f_rnd = IS_IETF ? 4'd9 : 4'd8;
                default: f_rnd = IS_IETF ? 4'd7 : 4'd6;
            endcase
        end
    endfunction

    //==========================================================================
    // storage
    //==========================================================================

    reg  [1:0]   kx_state_ff;           // K_IDLE / K_INIT / K_RUN / K_FIN
    reg  [3:0]   kx_slot_ff;            // slot s = 1 .. 8
    reg  [3:0]   kx_upd_ff;             // UpdateKS index i = 1 .. R
    reg          kx_mode_ff;            // sampled DIR-forced mode
    reg  [1:0]   kx_klen_ff;            // sampled KLEN (R_0 composition)
    reg  [3:0]   kx_rnd_ff;             // sampled R
    reg  [4:0]   kx_ctr_d_ff;           // counter of the previous cycle (L_i = R ^ <2i+1>)
    reg  [255:0] wk_ff;                 // whitening key

    //==========================================================================
    // decode
    //==========================================================================

    wire         st_init  = (kx_state_ff == K_INIT);
    wire         st_run   = (kx_state_ff == K_RUN);
    wire         st_fin   = (kx_state_ff == K_FIN);
    wire         upd_last = (kx_upd_ff == kx_rnd_ff);
    wire         s1       = st_run && (kx_slot_ff == 4'd1);
    wire         s3       = st_run && (kx_slot_ff == 4'd3);
    wire         s4       = st_run && (kx_slot_ff == 4'd4);
    wire         s7       = st_run && (kx_slot_ff == 4'd7);
    wire         s8       = st_run && (kx_slot_ff == 4'd8);
    wire [4:0]   i2       = {kx_upd_ff, 1'b0};          // 2i

    // K_int = L_0 || R_0 on 64-bit words w0..w7 (w0 = cfg_key[511:448]):
    //   k=512 w0..w7; k=384 w0..w5 ~w2 ~w3; k=256 w0..w3 ~w0..~w3
    wire [255:0] l0 = cfg_key[511:256];
    wire [255:0] r0 = (kx_klen_ff == 2'd0) ? ~cfg_key[511:256]
                    : (kx_klen_ff == 2'd1) ? {cfg_key[255:128], ~cfg_key[383:256]}
                    :                        cfg_key[255:0]
                    ;

    // counter of this cycle: INIT <1>, s = 4 <2i>, s = 8 <2i+1> (i < R), else 0
    wire [4:0]   ctr = st_init                ? 5'd1
                     : s4                     ? i2
                     : (s8 && (!upd_last))    ? (i2 + 5'd1)
                     :                          5'd0
                     ;

    wire [255:0] r_i   = r_xw ^ mrk_rdata;     // R_i = L_i ^ G at s = 8 (G read back at s = 7)
    wire [255:0] r_prv = (kx_upd_ff == 4'd1) ? r0 : mrk_rdata;   // R_{i-1} at s = 4 (read at s = 3)
    wire         wr_l  = (s1 && (kx_upd_ff != 4'd1)) || st_fin;  // L_{i} write, one cycle after s = 8

    //==========================================================================
    // sequencer
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            kx_state_ff <= K_IDLE;
            kx_slot_ff  <= 4'd0;
            kx_upd_ff   <= 4'd0;
        end else if (cfg_vld) begin
            kx_state_ff <= K_IDLE;              // abort / restart (OP-6)
            kx_slot_ff  <= 4'd0;
            kx_upd_ff   <= 4'd0;
        end else if (kx_start) begin
            kx_state_ff <= K_INIT;
            kx_slot_ff  <= 4'd0;
            kx_upd_ff   <= 4'd1;
        end else begin
            case (kx_state_ff)
                K_INIT : begin
                    kx_state_ff <= K_RUN;
                    kx_slot_ff  <= 4'd1;
                end
                K_RUN : begin
                    if (s8) begin
                        kx_slot_ff <= 4'd1;
                        if (upd_last) begin
                            kx_state_ff <= K_FIN;
                        end else begin
                            kx_upd_ff   <= kx_upd_ff + 4'd1;
                        end
                    end else begin
                        kx_slot_ff <= kx_slot_ff + 4'd1;
                    end
                end
                K_FIN : begin
                    kx_state_ff <= K_IDLE;
                end
                default : begin
                    kx_state_ff <= K_IDLE;
                end
            endcase // kx_state_ff
        end
    end

    // sampled request (at cfg_vld, like vb_mkv_key_ld)
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            kx_mode_ff <= 1'b0;
            kx_klen_ff <= 2'd0;
            kx_rnd_ff  <= 4'd0;
        end else if (cfg_vld) begin
            kx_mode_ff <= DIR_ENC ? 1'b0 : (DIR_DEC ? 1'b1 : cfg_mode);
            kx_klen_ff <= cfg_klen;
            kx_rnd_ff  <= f_rnd(cfg_klen);
        end
    end

    always @(posedge clk) begin
        kx_ctr_d_ff <= ctr;
    end

    // whitening key: enc L_0 (INIT), dec raw K_post = R_R (s = 8 of the last step)
    // voptimize T6-A: the whitening-key source uses the DIR constant in DEC builds (kx_mode_ff resets to 0
    // and loads 1, which would keep both sources); ENC: kx_mode_ff is already constant 0 (reset 0, load 0)
    wire         wk_dec = DIR_DEC ? 1'b1 : kx_mode_ff;
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            wk_ff <= 256'd0;
        end else if (st_init && (!wk_dec)) begin
            wk_ff <= l0;
        end else if (s8 && upd_last && wk_dec) begin
            wk_ff <= r_i;
        end
    end

    //==========================================================================
    // outputs
    //==========================================================================

    assign kx_busy  = (kx_state_ff != K_IDLE);
    assign kx_done  = st_fin;
    assign kx_mode  = kx_mode_ff;
    assign kx_rnd   = kx_rnd_ff;
    assign kx_wk    = wk_ff;

    assign ks_ld    = st_init || s4;
    assign ks_ph    = !kx_slot_ff[0];
    assign ks_src   = st_init ? l0 : r_prv;
    assign ks_kt    = {251'd0, ctr};

    // writes: INIT L_0 -> 0; s = 4 G -> 2i (parked); s = 8 R_i -> 2i; s = 1 of i+1 / FIN L_i -> 2i-1
    assign mrk_st    = st_init || s4 || s8 || wr_l;
    assign mrk_waddr = st_init      ? 5'd0
                     : (s4 || s8)   ? i2
                     : st_fin       ? (i2 - 5'd1)
                     :                (i2 - 5'd3)
                     ;
    assign mrk_wdata = st_init ? l0
                     : s4      ? r_xw
                     : s8      ? r_i
                     :           (r_q ^ {251'd0, kx_ctr_d_ff})
                     ;
    assign mrk_ld    = s3 || s7;
    assign mrk_raddr = s3 ? (i2 - 5'd2) : i2;

endmodule

`default_nettype wire
