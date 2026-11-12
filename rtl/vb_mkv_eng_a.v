`default_nettype none

// vb_mkv_eng_a : engine A = complete 2-cycle-round MKV-128 core for TARGET = "ASIC" and for
//   TARGET = "FPGA" + SBOX_IMPL = "LOGIC" (arch v4 section 14, REQ-V4-1/2/4, ddoc/vb_mkv_eng_a_req.md)
//   icfg (vb_mkv_cfg, shared config protocol) + key source (ikx: vb_mkv_kx_a INT | vb_mkv_key_ld EXT)
//   + iseq (vb_mkv_seq_a block sequencer) + iround (vb_mkv_round_a) + irk_store (lib vb_sdp_ram_pp)
//   Port list = v3 vb_mkv_core port list. The registered mode select dec_ff (and vb_mkv_cfg act_mode)
//   changes only while no block is in flight: false-path candidate for the ASIC STA (REQ / proposal).
module vb_mkv_eng_a #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH"
    parameter TARGET    = "ASIC",       //! "ASIC": store RAM_TYPE from RKS_IMPL | "FPGA": "DISTRIBUTED"
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" | "IETF2026" (store DEPTH 17 / 19)
    parameter KEY_SCHED = "INT",        //! "INT": on-chip key schedule | "EXT": software-loaded round keys
    parameter RKS_IMPL  = "FF",         //! ASIC store: "FF" | "LATCH" | "MACRO"
    parameter RS_LV     = 0             //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port
    input  wire         cfg_vld,        //! 1-cycle strobe: start / restart key setup
    input  wire         cfg_mode,       //! 0 = encrypt, 1 = decrypt (DIR = "BOTH")
    input  wire [1:0]   cfg_klen,       //! 0/1/2 = 128/192/256, 3 = invalid
    input  wire [255:0] cfg_key,        //! INT {MK0..MK7} (stable while cfg_busy, MK lock); EXT [255:128] staging key
    output wire         cfg_busy,       //! request validating / pending / running
    output wire         cfg_err,        //! reject pulse (P-A6)
    input  wire         cfg_rk_wr,      //! EXT round-key commit pulse, data cfg_key[255:128]; ignored in INT
    input  wire [4:0]   cfg_rk_idx,     //! EXT store index of the commit; ignored in INT
    output wire         cfg_ldrdy,      //! EXT load window open; 0 in INT
    output wire         cfg_rk_drop,    //! EXT 1-cycle pulse: a commit was not stored; 0 in INT

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
    localparam KS_INT   = (KEY_SCHED == "INT") ? 1 : 0;
    localparam ENA_FWD  = ((DIR == "DEC") && (KS_INT == 0)) ? 0 : 1;   // DEC + EXT: inverse-only (REQ-V3-3)
    localparam IS_FPGA  = (TARGET == "FPGA") ? 1 : 0;
    localparam DIR_ENC  = (DIR == "ENC") ? 1'b1 : 1'b0;
    localparam DIR_DEC  = (DIR == "DEC") ? 1'b1 : 1'b0;
    localparam RKS_DEPTH = (PROFILE == "IETF2026") ? 19 : 17;          // 2 R_MAX + 1
    localparam RKS_TYPE  = (IS_FPGA != 0)       ? "DISTRIBUTED"
                         : (RKS_IMPL == "LATCH") ? "ASIC_LATCH"
                         : (RKS_IMPL == "MACRO") ? "ASIC_MACRO"
                         :                         "ASIC_FF"
                         ;
    /* verilator lint_on WIDTHEXPAND */
    localparam LD_FORM   = (KS_INT != 0) ? "PRE" : "POST";             // dec wk raw (INT) / XW(K_post) (EXT)
    localparam RS_ACT    = (RS_LV != 0) ? 1'b1 : 1'b0;

    //==========================================================================
    // inter-module nets
    //==========================================================================

    // key source -> cfg / engine
    wire         kx_start;
    wire         kx_busy;
    wire         kx_done;
    wire         kx_mode;
    wire [3:0]   kx_rnd;
    wire [127:0] kx_wk;

    // cfg -> block side
    wire         key_valid;
    wire         act_mode;
    wire [3:0]   act_rnd;
    wire         eng_idle;

    // round-key store
    wire         mrk_st;
    wire [4:0]   mrk_waddr;
    wire [127:0] mrk_wdata;
    wire         mrk_ld;
    wire [4:0]   mrk_raddr;
    wire [127:0] mrk_rdata;

    // key schedule -> round / store (INT; tied off in EXT)
    wire         ks_act;                // key schedule owns the datapath and the store read port
    wire         ks_ld;
    wire         ks_ph;
    wire [127:0] ks_src;
    wire [127:0] ks_kt;
    wire         ks_mrk_ld;
    wire [4:0]   ks_mrk_raddr;

    // block sequencer -> round / store
    wire         blk_en;
    wire         blk_ld;
    wire         blk_ph;
    wire         blk_mrk_ld;
    wire [4:0]   blk_mrk_raddr;

    // round
    wire [127:0] r_q;
    wire [127:0] r_xw;
    wire [127:0] r_res;

    //==========================================================================
    // configure-port protocol (shared with engine T)
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
    // key source: INT key schedule on the datapath | EXT software load window
    //==========================================================================

    generate
        if (KS_INT != 0) begin : g_ks_int
            vb_mkv_kx_a #(
                .DIR     (DIR),
                .PROFILE (PROFILE),
                .RS_LV   (RS_LV)
            ) ikx (
                .clk       (clk),
                .rst_n     (rst_n),
                .cfg_vld   (cfg_vld),
                .cfg_mode  (cfg_mode),
                .cfg_klen  (cfg_klen),
                .cfg_key   (cfg_key),
                .kx_start  (kx_start),
                .kx_busy   (kx_busy),
                .kx_done   (kx_done),
                .kx_mode   (kx_mode),
                .kx_rnd    (kx_rnd),
                .kx_wk     (kx_wk),
                .ks_ld     (ks_ld),
                .ks_ph     (ks_ph),
                .ks_src    (ks_src),
                .ks_kt     (ks_kt),
                .r_xw      (r_xw),
                .r_q       (r_q),
                .mrk_st    (mrk_st),
                .mrk_waddr (mrk_waddr),
                .mrk_wdata (mrk_wdata),
                .mrk_ld    (ks_mrk_ld),
                .mrk_raddr (ks_mrk_raddr),
                .mrk_rdata (mrk_rdata)
            );
            assign ks_act      = kx_busy;
            assign cfg_ldrdy   = 1'b0;      /* INT: no software load window */
            assign cfg_rk_drop = 1'b0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_cmt = cfg_rk_wr | (|cfg_rk_idx);
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_ks_ext
            vb_mkv_key_ld #(
                .DIR     (DIR),
                .PROFILE (PROFILE),
                .RS_LV   (RS_LV)
            ) ikx (
                .clk        (clk),
                .rst_n      (rst_n),
                .cfg_vld    (cfg_vld),
                .cfg_mode   (cfg_mode),
                .cfg_klen   (cfg_klen),
                .cfg_key    (cfg_key),
                .cfg_rk_wr  (cfg_rk_wr),
                .cfg_rk_idx (cfg_rk_idx),
                .kx_start   (kx_start),
                .kx_busy    (kx_busy),
                .kx_done    (kx_done),
                .kx_mode    (kx_mode),
                .kx_rnd     (kx_rnd),
                .kx_wk      (kx_wk),
                .mrk_st     (mrk_st),
                .mrk_waddr  (mrk_waddr),
                .mrk_wdata  (mrk_wdata),
                .kx_rk_drop (cfg_rk_drop)
            );
            assign ks_act       = 1'b0;     /* EXT: the window never uses the datapath */
            assign ks_ld        = 1'b0;
            assign ks_ph        = 1'b0;
            assign ks_src       = 128'd0;
            assign ks_kt        = 128'd0;
            assign ks_mrk_ld    = 1'b0;
            assign ks_mrk_raddr = 5'd0;
            assign cfg_ldrdy    = kx_busy;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_kl = (|r_xw) | (|r_q);
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    //==========================================================================
    // block sequencer
    //==========================================================================

    vb_mkv_seq_a #(
        .DIR   (DIR),
        .RS_LV (RS_LV)
    ) iseq (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_valid  (key_valid),
        .cfg_vld    (cfg_vld),
        .act_mode   (act_mode),
        .act_rnd    (act_rnd),
        .eng_idle   (eng_idle),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready),
        .dout_data  (dout_data),
        .r_res      (r_res),
        .blk_en     (blk_en),
        .blk_ld     (blk_ld),
        .blk_ph     (blk_ph),
        .mrk_ld     (blk_mrk_ld),
        .mrk_raddr  (blk_mrk_raddr)
    );

    //==========================================================================
    // round-key store (memory M1): raw keys, v3 index map, 1-cycle registered read
    //==========================================================================

    assign mrk_ld    = ks_act ? ks_mrk_ld    : blk_mrk_ld;
    assign mrk_raddr = ks_act ? ks_mrk_raddr : blk_mrk_raddr;

    vb_sdp_ram_pp #(
        .AWIDTH   (5),
        .DWIDTH   (128),
        .DEPTH    (RKS_DEPTH),
        .RAM_TYPE (RKS_TYPE),
        .PIPELINE (0),
        .INPUTREG ("OFF")
    ) irk_store (
        .clk   (clk),
        .st    (mrk_st),
        .waddr (mrk_waddr),
        .wdata (mrk_wdata),
        .ld    (mrk_ld),
        .raddr (mrk_raddr),
        .rdata (mrk_rdata)
    );

    //==========================================================================
    // round datapath
    //==========================================================================

    // registered inverse select: changes only at key-setup boundaries (INIT and the first block cycle
    // are loads), so the S-box -> mux paths from dec_ff are quasi-static
    // voptimize T6-A: in single-direction builds the block direction is the DIR constant (DEC: every block
    // decrypts, the forward arm only runs F0 during key setup), so synthesis prunes the unused forms;
    // act_mode (reset 0, loaded 1) would keep them. BOTH: act_mode. (vb_mkv_seq_a keeps act_mode, T-7.)
    reg          dec_ff;
    wire         dec_nx = (ENA_FWD == 0) ? 1'b1
                        : DIR_ENC        ? 1'b0
                        : DIR_DEC        ? (!ks_act)
                        :                  (act_mode && (!ks_act))
                        ;
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            dec_ff <= (ENA_FWD == 0) ? 1'b1 : 1'b0;
        end else begin
            dec_ff <= dec_nx;
        end
    end

    vb_mkv_round_a #(
        .DIR     (DIR),
        .ENA_FWD (ENA_FWD),
        .LD_FORM (LD_FORM)
    ) iround (
        .clk    (clk),
        .en     (ks_act || blk_en),
        .ld     (ks_act ? ks_ld  : blk_ld),
        .ph     (ks_act ? ks_ph  : blk_ph),
        .dec    (dec_ff),
        .ld_xw  (dec_nx),
        .ld_src (ks_act ? ks_src : din_data),
        .ld_key (ks_act ? ks_kt  : kx_wk),
        .k      (ks_act ? ks_kt  : mrk_rdata),
        .r_q    (r_q),
        .r_xw   (r_xw),
        .res    (r_res)
    );

endmodule

`default_nettype wire
