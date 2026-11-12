`default_nettype none

// vb_mkv_eng_t : engine T, MKV-128 core for TARGET = "FPGA" + SBOX_IMPL = "BRAM" (arch v4 section 14.2/14.3)
//   2-cycle T-box round (vb_mkv_round_t, 8 x vb_mkv_tbox_rom = 8 RAMB36), block sequencer vb_mkv_seq_t,
//   key source vb_mkv_kx_t (INT key schedule / EXT store-format conversion), vb_mkv_key_ld (EXT window),
//   shared configure protocol vb_mkv_cfg, round-key store irk_store (lib vb_sdp_ram_pp, DISTRIBUTED).
//   Port list = v3 core port list. Interval 2R, latency 2R+1, INT setup ENC 8R+6 / DEC 10R+8 (cfg_vld ->
//   cfg_busy fall, engine idle).
module vb_mkv_eng_t #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH"
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" | "IETF2026"
    parameter KEY_SCHED = "INT",        //! "INT": on-chip key schedule | "EXT": software-loaded round keys
    parameter RS_LV     = 0             //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port
    input  wire         cfg_vld,        //! 1-cycle strobe: start / restart key setup
    input  wire         cfg_mode,       //! 0 = encrypt, 1 = decrypt (DIR = "BOTH")
    input  wire [1:0]   cfg_klen,       //! 0/1/2 = 128/192/256, 3 = invalid
    input  wire [255:0] cfg_key,        //! INT: {MK0..MK7} (MK0 in [255:224]); EXT: [255:128] staging key
    output wire         cfg_busy,       //! request validating / pending / running
    output wire         cfg_err,        //! reject pulse (P-A6)
    input  wire         cfg_rk_wr,      //! EXT round-key commit pulse; ignored in INT
    input  wire [4:0]   cfg_rk_idx,     //! EXT commit index; ignored in INT
    output wire         cfg_ldrdy,      //! EXT load window open; 0 in INT
    output wire         cfg_rk_drop,    //! EXT dropped-commit pulse (T-5); 0 in INT

    // input block stream
    input  wire         din_valid,      //! input block valid
    output wire         din_ready,      //! engine accepts a block
    input  wire [127:0] din_data,       //! input block, B[0] in [127:120]

    // output block stream
    output wire         dout_valid,     //! output block valid (registered)
    input  wire         dout_ready,     //! sink ready
    output wire [127:0] dout_data       //! output block (registered), B[0] in [127:120]
);

    /* verilator lint_off WIDTHEXPAND */
    localparam KS_EXT    = (KEY_SCHED == "EXT") ? 1 : 0;
    localparam IS_IETF   = (PROFILE == "IETF2026") ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */
    localparam RKS_DEPTH = (IS_IETF != 0) ? 19 : 17;
    localparam DIR_DEC   = (DIR == "DEC") ? 1 : 0;
    localparam DIR_ENC   = (DIR == "ENC") ? 1 : 0;

    //==========================================================================
    // nets
    //==========================================================================

    // cfg <-> key source / sequencer
    wire         kx_start, kx_busy, kx_done, kx_mode;
    wire [3:0]   kx_rnd;
    wire         eng_idle, key_valid, act_mode;
    wire [3:0]   act_rnd;

    // key_ld (EXT)
    wire         kl_busy, kl_done, kl_mode, kl_st;
    wire [3:0]   kl_rnd;
    wire [4:0]   kl_waddr;
    wire [127:0] kl_wdata, kl_wk;

    // store
    wire         rks_st;
    wire [4:0]   rks_waddr, rks_raddr;
    wire [127:0] rks_wdata, rks_rdata;

    // sequencer
    wire         sq_gate_nx, sq_ben, sq_dout_ce, sq_ld_dec, sq_dout_dec;
    wire [1:0]   sq_asel_nx, sq_hs_nx;
    wire [4:0]   sq_raddr;

    // key source datapath controls
    wire         kx_own, kx_own_nx, kx_gate_nx, kx_tsel_nx, kx_xws_nx, kx_ben;
    wire [1:0]   kx_asel_nx, kx_hs_nx;
    wire         kx_kt_kp, kx_kt_zero, kx_kp_ce, kx_kp_sel, kx_tap_ce;
    wire [4:0]   kx_ctr, kx_raddr;
    wire [127:0] kx_kp_in, kx_wk, tap;

    //==========================================================================
    // configure protocol (shared, vb_mkv_cfg)
    //==========================================================================

    vb_mkv_cfg #(
        .DIR   (DIR),
        .RS_LV (RS_LV)
    ) icfg (
        .clk       (clk),
        .rst_n     (rst_n),
        .cfg_vld   (cfg_vld),
        .cfg_klen  (cfg_klen),
        .cfg_busy  (cfg_busy),
        .cfg_err   (cfg_err),
        .kx_start  (kx_start),
        .kx_busy   (kx_busy),
        .kx_done   (kx_done),
        .kx_mode   (kx_mode),
        .kx_rnd    (kx_rnd),
        .eng_idle  (eng_idle),
        .key_valid (key_valid),
        .act_mode  (act_mode),
        .act_rnd   (act_rnd)
    );

    //==========================================================================
    // EXT load window (vb_mkv_key_ld, unchanged)
    //==========================================================================

    generate
        if (KS_EXT != 0) begin : g_ext
            vb_mkv_key_ld #(
                .DIR     (DIR),
                .PROFILE (PROFILE),
                .RS_LV   (RS_LV)
            ) ikey_ld (
                .clk        (clk),
                .rst_n      (rst_n),
                .cfg_vld    (cfg_vld),
                .cfg_mode   (cfg_mode),
                .cfg_klen   (cfg_klen),
                .cfg_key    (cfg_key),
                .cfg_rk_wr  (cfg_rk_wr),
                .cfg_rk_idx (cfg_rk_idx),
                .kx_start   (kx_start),
                .kx_busy    (kl_busy),
                .kx_done    (kl_done),
                .kx_mode    (kl_mode),
                .kx_rnd     (kl_rnd),
                .kx_wk      (kl_wk),
                .mrk_st     (kl_st),
                .mrk_waddr  (kl_waddr),
                .mrk_wdata  (kl_wdata),
                .kx_rk_drop (cfg_rk_drop)
            );
            assign cfg_ldrdy = kl_busy;                 // load window only (not the conversion pass)
        end else begin : g_int
            assign kl_busy     = 1'b0;
            assign kl_done     = 1'b0;
            assign kl_mode     = 1'b0;
            assign kl_rnd      = 4'd0;
            assign kl_st       = 1'b0;
            assign kl_waddr    = 5'd0;
            assign kl_wdata    = 128'd0;
            assign kl_wk       = 128'd0;
            assign cfg_ldrdy   = 1'b0;
            assign cfg_rk_drop = 1'b0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_cmt = cfg_rk_wr | (|cfg_rk_idx);   /* INT: commit port ignored */
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    //==========================================================================
    // key source: INT key schedule / store-format conversion (vb_mkv_kx_t)
    //==========================================================================

    vb_mkv_kx_t #(
        .DIR       (DIR),
        .PROFILE   (PROFILE),
        .KEY_SCHED (KEY_SCHED),
        .RS_LV     (RS_LV)
    ) ikx (
        .clk         (clk),
        .rst_n       (rst_n),
        .cfg_vld     (cfg_vld),
        .cfg_mode    (cfg_mode),
        .cfg_klen    (cfg_klen),
        .cfg_key     (cfg_key),
        .kx_start    (kx_start),
        .kl_busy     (kl_busy),
        .kl_done     (kl_done),
        .kl_mode     (kl_mode),
        .kl_rnd      (kl_rnd),
        .kl_st       (kl_st),
        .kl_waddr    (kl_waddr),
        .kl_wdata    (kl_wdata),
        .kl_wk       (kl_wk),
        .kx_busy     (kx_busy),
        .kx_done     (kx_done),
        .kx_mode     (kx_mode),
        .kx_rnd      (kx_rnd),
        .tap         (tap),
        .own         (kx_own),
        .own_nx      (kx_own_nx),
        .gate_nx     (kx_gate_nx),
        .asel_nx     (kx_asel_nx),
        .hs_nx       (kx_hs_nx),
        .tsel_nx     (kx_tsel_nx),
        .xws_nx      (kx_xws_nx),
        .ben         (kx_ben),
        .kt_sel_kp   (kx_kt_kp),
        .kt_sel_zero (kx_kt_zero),
        .ctr         (kx_ctr),
        .kp_ce       (kx_kp_ce),
        .kp_sel_in   (kx_kp_sel),
        .kp_in       (kx_kp_in),
        .tap_ce      (kx_tap_ce),
        .raddr       (kx_raddr),
        .wk          (kx_wk),
        .st          (rks_st),
        .waddr       (rks_waddr),
        .wdata       (rks_wdata)
    );

    //==========================================================================
    // block sequencer (vb_mkv_seq_t)
    //==========================================================================

    // datapath mode: a per-DIR constant in single-direction builds (voptimize T6; cfg act_mode resets to 0 and
    // loads 1 in DIR = "DEC", which keeps the encryption logic). BOTH: cfg act_mode, the new mode at kx_done.
    wire         sq_mode    = (DIR_DEC != 0) ? 1'b1 : (DIR_ENC != 0) ? 1'b0 : act_mode;
    wire         sq_mode_nx = (DIR_DEC != 0) ? 1'b1 : (DIR_ENC != 0) ? 1'b0
                            : (kx_done ? kx_mode : act_mode);      // cfg latches act_mode at kx_done

    vb_mkv_seq_t #(
        .RS_LV (RS_LV)
    ) iseq (
        .clk        (clk),
        .rst_n      (rst_n),
        .cfg_vld    (cfg_vld),
        .key_valid  (key_valid),
        .act_mode   (sq_mode),
        .mode_nx    (sq_mode_nx),
        .act_rnd    (act_rnd),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready),
        .eng_idle   (eng_idle),
        .ld_dec     (sq_ld_dec),
        .dout_dec   (sq_dout_dec),
        .gate_nx    (sq_gate_nx),
        .asel_nx    (sq_asel_nx),
        .hs_nx      (sq_hs_nx),
        .ben        (sq_ben),
        .dout_ce    (sq_dout_ce),
        .raddr      (sq_raddr)
    );

    //==========================================================================
    // round-key store (lib vb_sdp_ram_pp, LUTRAM, 1-cycle registered read, always reading)
    //==========================================================================

    assign rks_raddr = kx_own ? kx_raddr : sq_raddr;

    vb_sdp_ram_pp #(
        .AWIDTH   (5),
        .DWIDTH   (128),
        .DEPTH    (RKS_DEPTH),
        .RAM_TYPE ("DISTRIBUTED"),
        .PIPELINE (0),
        .INPUTREG ("OFF")
    ) irk_store (
        .clk   (clk),
        .st    (rks_st),
        .waddr (rks_waddr),
        .wdata (rks_wdata),
        .ld    (1'b1),
        .raddr (rks_raddr),
        .rdata (rks_rdata)
    );

    //==========================================================================
    // T-box datapath (vb_mkv_round_t); the key source owns it during key setup / conversion
    //==========================================================================

    vb_mkv_round_t #(
        .DIR   (DIR),
        .RS_LV (RS_LV)
    ) iround (
        .clk         (clk),
        .rst_n       (rst_n),
        .gate_nx     (kx_own_nx ? kx_gate_nx : sq_gate_nx),
        .asel_nx     (kx_own_nx ? kx_asel_nx : sq_asel_nx),
        .hs_nx       (kx_own_nx ? kx_hs_nx   : sq_hs_nx),
        .tsel_nx     (kx_own_nx & kx_tsel_nx),
        .xws_nx      (kx_own_nx & kx_xws_nx),
        .ben         (kx_own ? kx_ben : sq_ben),
        .ld_dec      (sq_ld_dec),
        .din         (din_data),
        .wk          (kx_wk),
        .rk          (rks_rdata),
        .kt_sel_kp   (kx_own & kx_kt_kp),
        .kt_sel_zero (kx_own & kx_kt_zero),
        .ctr         (kx_ctr),
        .kp_ce       (kx_kp_ce),
        .kp_sel_in   (kx_kp_sel),
        .kp_in       (kx_kp_in),
        .tap_ce      (kx_tap_ce),
        .dout_ce     (sq_dout_ce),
        .dout_dec    (sq_dout_dec),
        .tap         (tap),
        .dout_data   (dout_data)
    );

endmodule

`default_nettype wire
