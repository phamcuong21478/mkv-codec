`default_nettype none

// vb_mkv_core : MKV-128 / MKV-256 iterative cipher engine (configure port + block stream), thin selector
//   (arch v4 §14, v5.1 §15.15.6). Parameter legality + engine choice:
//     BLOCK=128: FPGA + BRAM -> vb_mkv_eng_t (T-box), otherwise vb_mkv_eng_a (ASIC, FPGA LOGIC)
//     BLOCK=256: FPGA + BRAM -> vb_mkv_eng_t256,      otherwise vb_mkv_eng_a256 (DEC_ARCH JDOM | SEP)
//   Every engine has exactly this port list (BLOCK-wide data, 2*BLOCK-wide key); key schedule / store live
//   inside them. BLOCK=128: the v4 engine branches and port widths are unchanged.
module vb_mkv_core #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH"
    parameter TARGET    = "FPGA",       //! "FPGA" (C1/C2/C3 timing structure) | "ASIC" (area structure), v2
    parameter SBOX_IMPL = (TARGET == "ASIC") ? "LOGIC" : "BRAM",  //! "BRAM" | "LOGIC" ("LUT" = alias of LOGIC)
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" | "IETF2026"
    parameter KEY_SCHED = "INT",        //! "INT": on-chip key schedule | "EXT": software-loaded round keys (v3)
    parameter RKS_IMPL  = "FF",         //! "FF" | "LATCH" | "MACRO": round-key store for TARGET = "ASIC" (v3)
    parameter RS_LV     = 0,            //! reset active level (0 = active-low)
    parameter BLOCK     = 128,          //! block size 128 | 256 (v5; appended after RS_LV for positional compatibility)
    parameter DEC_ARCH  = "JDOM"        //! "JDOM" | "SEP": engine A256 decryption form, BLOCK=256 and DIR != ENC only (v5.1)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port
    input  wire         cfg_vld,        //! 1-cycle strobe: start / restart key setup
    input  wire         cfg_mode,       //! 0 = encrypt, 1 = decrypt (DIR = "BOTH")
    input  wire [1:0]   cfg_klen,       //! 0/1/2 = 128/192/256 (BLOCK=256: 256/384/512), 3 = invalid
    input  wire [2*BLOCK-1:0] cfg_key,  //! {MK0..MK7} (BLOCK=256: {MK0..MK15}), MK0 in the MS word
    output wire         cfg_busy,       //! request validating/pending/running
    output wire         cfg_err,        //! reject pulse, in the cfg_busy fall cycle unless a new cfg_vld followed
    input  wire         cfg_rk_wr,      //! (v3, EXT) round-key commit pulse, data cfg_key[2*BLOCK-1:BLOCK]; ignored in INT
    input  wire [4:0]   cfg_rk_idx,     //! (v3, EXT) store index of the commit; ignored in INT
    output wire         cfg_ldrdy,      //! (v3, EXT) load window open (= kx_busy); 0 in INT
    output wire         cfg_rk_drop,    //! (v3, EXT) 1-cycle pulse: a forwarded commit was not stored (-> ERR, vtrace T-5); 0 in INT

    // input block stream
    input  wire         din_valid,      //! input block valid
    output wire         din_ready,      //! core accepts a block
    input  wire [BLOCK-1:0] din_data,   //! input block, B[0] in [BLOCK-1:BLOCK-8]

    // output block stream
    output wire         dout_valid,     //! output block valid
    input  wire         dout_ready,     //! sink ready
    output wire [BLOCK-1:0] dout_data   //! output block, B[0] in [BLOCK-1:BLOCK-8]
);

    //==========================================================================
    // parameter legality (LSN-7)
    //==========================================================================

    // an illegal value instantiates an undefined module -> elaboration fails with a self-explaining name
    /* verilator lint_off WIDTHEXPAND */  /* string parameters compared against literals of other lengths */
    generate
        if ((DIR != "ENC") && (DIR != "DEC") && (DIR != "BOTH")) begin : g_err_dir
            vb_mkv_illegal_param_DIR ierr_dir ();
        end
        if ((SBOX_IMPL != "BRAM") && (SBOX_IMPL != "LOGIC") && (SBOX_IMPL != "LUT")) begin : g_err_sbox
            vb_mkv_illegal_param_SBOX_IMPL ierr_sbox ();         /* "LUT" = deprecated alias of "LOGIC" */
        end
        if ((TARGET != "FPGA") && (TARGET != "ASIC")) begin : g_err_target
            vb_mkv_illegal_param_TARGET ierr_target ();
        end
        if ((TARGET == "ASIC") && (SBOX_IMPL == "BRAM")) begin : g_err_asic_bram
            vb_mkv_illegal_param_ASIC_BRAM ierr_asic_bram ();    /* BRAM is FPGA-only */
        end
        if ((PROFILE != "TCVN2024") && (PROFILE != "IETF2026")) begin : g_err_prof
            vb_mkv_illegal_param_PROFILE ierr_prof ();
        end
        if ((RS_LV != 0) && (RS_LV != 1)) begin : g_err_rslv
            vb_mkv_illegal_param_RS_LV ierr_rslv ();
        end
        if ((KEY_SCHED != "INT") && (KEY_SCHED != "EXT")) begin : g_err_ks
            vb_mkv_illegal_param_KEY_SCHED ierr_ks ();
        end
        if ((RKS_IMPL != "FF") && (RKS_IMPL != "LATCH") && (RKS_IMPL != "MACRO")) begin : g_err_rks
            vb_mkv_illegal_param_RKS_IMPL ierr_rks ();
        end
        if ((BLOCK != 128) && (BLOCK != 256)) begin : g_err_blk
            vb_mkv_illegal_param_BLOCK ierr_blk ();              /* v5 */
        end
        if ((DEC_ARCH != "JDOM") && (DEC_ARCH != "SEP")) begin : g_err_decarch
            vb_mkv_illegal_param_DEC_ARCH ierr_decarch ();       /* v5.1: checked for every build, also where ignored */
        end
    endgenerate


    // S-box choice normalised once here: the "LUT" alias selects the LOGIC (engine A) datapath
    localparam SB_IMPL = (SBOX_IMPL == "BRAM") ? "BRAM" : "LOGIC";
    // v4 §14.4: engine T (BRAM T-box) for FPGA + BRAM, engine A for ASIC and FPGA LOGIC
    // (v5.1 §15.15.1: same split at BLOCK=256 -> engine T256 / engine A256)
    localparam ENG_T   = ((TARGET == "FPGA") && (SB_IMPL == "BRAM")) ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */

    //==========================================================================
    // engine (pass-through of every core port)
    //==========================================================================

    generate
        if ((BLOCK == 256) && (ENG_T == 1)) begin : g_eng_t256
            vb_mkv_eng_t256 #(
                .DIR       (DIR),
                .PROFILE   (PROFILE),
                .KEY_SCHED (KEY_SCHED),
                .RS_LV     (RS_LV)
            ) ieng (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_vld     (cfg_vld),
                .cfg_mode    (cfg_mode),
                .cfg_klen    (cfg_klen),
                .cfg_key     (cfg_key),
                .cfg_busy    (cfg_busy),
                .cfg_err     (cfg_err),
                .cfg_rk_wr   (cfg_rk_wr),
                .cfg_rk_idx  (cfg_rk_idx),
                .cfg_ldrdy   (cfg_ldrdy),
                .cfg_rk_drop (cfg_rk_drop),
                .din_valid   (din_valid),
                .din_ready   (din_ready),
                .din_data    (din_data),
                .dout_valid  (dout_valid),
                .dout_ready  (dout_ready),
                .dout_data   (dout_data)
            );
            /* verilator lint_off UNUSEDPARAM */
            localparam UNUSED_RKS = RKS_IMPL;           /* RKS_IMPL ignored for FPGA (LUTRAM store) */
            localparam UNUSED_DA  = DEC_ARCH;           /* DEC_ARCH ignored by engine T256 (v5.1 §15.15.2) */
            /* verilator lint_on UNUSEDPARAM */
        end else if (BLOCK == 256) begin : g_eng_a256
            vb_mkv_eng_a256 #(
                .DIR       (DIR),
                .TARGET    (TARGET),
                .PROFILE   (PROFILE),
                .KEY_SCHED (KEY_SCHED),
                .RKS_IMPL  (RKS_IMPL),
                .DEC_ARCH  (DEC_ARCH),
                .RS_LV     (RS_LV)
            ) ieng (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_vld     (cfg_vld),
                .cfg_mode    (cfg_mode),
                .cfg_klen    (cfg_klen),
                .cfg_key     (cfg_key),
                .cfg_busy    (cfg_busy),
                .cfg_err     (cfg_err),
                .cfg_rk_wr   (cfg_rk_wr),
                .cfg_rk_idx  (cfg_rk_idx),
                .cfg_ldrdy   (cfg_ldrdy),
                .cfg_rk_drop (cfg_rk_drop),
                .din_valid   (din_valid),
                .din_ready   (din_ready),
                .din_data    (din_data),
                .dout_valid  (dout_valid),
                .dout_ready  (dout_ready),
                .dout_data   (dout_data)
            );
        end else if (ENG_T == 1) begin : g_eng_t
            vb_mkv_eng_t #(
                .DIR       (DIR),
                .PROFILE   (PROFILE),
                .KEY_SCHED (KEY_SCHED),
                .RS_LV     (RS_LV)
            ) ieng (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_vld     (cfg_vld),
                .cfg_mode    (cfg_mode),
                .cfg_klen    (cfg_klen),
                .cfg_key     (cfg_key),
                .cfg_busy    (cfg_busy),
                .cfg_err     (cfg_err),
                .cfg_rk_wr   (cfg_rk_wr),
                .cfg_rk_idx  (cfg_rk_idx),
                .cfg_ldrdy   (cfg_ldrdy),
                .cfg_rk_drop (cfg_rk_drop),
                .din_valid   (din_valid),
                .din_ready   (din_ready),
                .din_data    (din_data),
                .dout_valid  (dout_valid),
                .dout_ready  (dout_ready),
                .dout_data   (dout_data)
            );
            /* verilator lint_off UNUSEDPARAM */
            localparam UNUSED_RKS = RKS_IMPL;           /* RKS_IMPL ignored for FPGA (LUTRAM store) */
            /* verilator lint_on UNUSEDPARAM */
        end else begin : g_eng_a
            vb_mkv_eng_a #(
                .DIR       (DIR),
                .TARGET    (TARGET),
                .PROFILE   (PROFILE),
                .KEY_SCHED (KEY_SCHED),
                .RKS_IMPL  (RKS_IMPL),
                .RS_LV     (RS_LV)
            ) ieng (
                .clk         (clk),
                .rst_n       (rst_n),
                .cfg_vld     (cfg_vld),
                .cfg_mode    (cfg_mode),
                .cfg_klen    (cfg_klen),
                .cfg_key     (cfg_key),
                .cfg_busy    (cfg_busy),
                .cfg_err     (cfg_err),
                .cfg_rk_wr   (cfg_rk_wr),
                .cfg_rk_idx  (cfg_rk_idx),
                .cfg_ldrdy   (cfg_ldrdy),
                .cfg_rk_drop (cfg_rk_drop),
                .din_valid   (din_valid),
                .din_ready   (din_ready),
                .din_data    (din_data),
                .dout_valid  (dout_valid),
                .dout_ready  (dout_ready),
                .dout_data   (dout_data)
            );
        end
    endgenerate

endmodule

`default_nettype wire
