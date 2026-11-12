`default_nettype none

// vb_mkv_top : MKV-128 / MKV-256 iterative cipher IP top (spec name vb_mkv_su, REQ-NAME-1)
//   UPI register file (vb_mkv_reg) + cipher core (vb_mkv_core), see ddoc/vb_mkv_arch.md
//   (v3 §13: KEY_SCHED INT | EXT; EXT adds the reg <-> core round-key commit nets, IP ports unchanged)
//   (v5 §15 / v5.1 §15.15: BLOCK = 128 | 256 appended after RS_LV, then DEC_ARCH; BLOCK=128 keeps every v4
//    port width: din/dout 128, s_upi_addr 4, reg -> core key 256; BLOCK=256: 256 / 5 / 512)
module vb_mkv_top #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH"
    parameter TARGET    = "FPGA",       //! "FPGA" (C1/C2/C3 timing structure) | "ASIC" (area structure), v2
    parameter SBOX_IMPL = (TARGET == "ASIC") ? "LOGIC" : "BRAM",  //! "BRAM" | "LOGIC" ("LUT" = alias of LOGIC)
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" | "IETF2026"
    parameter KEY_SCHED = "INT",        //! "INT": on-chip key schedule | "EXT": software-loaded round keys (v3)
    parameter RKS_IMPL  = "FF",         //! "FF" | "LATCH" | "MACRO": round-key store for TARGET = "ASIC" (v3)
    parameter RS_LV     = 0,            //! reset active level (0 = active-low)
    parameter BLOCK     = 128,          //! block size 128 | 256 (v5; appended after RS_LV for positional compatibility)
    parameter DEC_ARCH  = "JDOM"        //! "JDOM" | "SEP": BLOCK=256 engine A256 decryption form (v5.1; ignored otherwise)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // UPI CPU register bus (slave)
    input  wire         s_upi_we,       //! write strobe
    input  wire         s_upi_oe,       //! read strobe
    input  wire [((BLOCK == 256) ? 5 : 4)-1:0] s_upi_addr,  //! word address (4 bit; 5 bit for BLOCK=256)
    input  wire [31:0]  s_upi_din,      //! write data
    output wire [31:0]  s_upi_dout,     //! read data, valid 1 cycle after s_upi_oe

    // input block stream
    input  wire         din_valid,      //! input block valid
    output wire         din_ready,      //! core accepts a block
    input  wire [BLOCK-1:0] din_data,   //! input block, B[0] in [BLOCK-1:BLOCK-8]

    // output block stream
    output wire         dout_valid,     //! output block valid
    input  wire         dout_ready,     //! sink accepts
    output wire [BLOCK-1:0] dout_data   //! output block, B[0] in [BLOCK-1:BLOCK-8]
);

    //==========================================================================
    // Inter-module interfaces
    //==========================================================================

    wire         reg2core_cfg_vld;      // reg -> core : start/restart key setup (pulse)
    wire         reg2core_cfg_mode;     // reg -> core : DIR-forced mode
    wire [1:0]   reg2core_cfg_klen;     // reg -> core : key length code
    wire [2*BLOCK-1:0] reg2core_cfg_key; // reg -> core : {MK0..MK7} (BLOCK=256: {MK0..MK15})
    wire         core2reg_cfg_busy;     // core -> reg : setup pending/running
    wire         core2reg_cfg_err;      // core -> reg : rejected configuration (pulse)
    wire         reg2core_cfg_rk_wr;    // reg -> core : (v3, EXT) validated round-key commit (pulse)
    wire [4:0]   reg2core_cfg_rk_idx;   // reg -> core : (v3, EXT) commit store index
    wire         core2reg_cfg_ldrdy;    // core -> reg : (v3, EXT) load window open (RKIDX.LDRDY)
    wire         core2reg_cfg_rk_drop;  // core -> reg : (v3, EXT) forwarded commit not stored -> ERR (T-5)

    //==========================================================================
    // Submodule instantiations
    //==========================================================================

    vb_mkv_reg #(
        .DIR       (DIR),
        .TARGET    (TARGET),
        .SBOX_IMPL (SBOX_IMPL),
        .PROFILE   (PROFILE),
        .KEY_SCHED (KEY_SCHED),
        .RS_LV     (RS_LV),
        .BLOCK     (BLOCK)
    ) ireg (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_upi_we   (s_upi_we),
        .s_upi_oe   (s_upi_oe),
        .s_upi_addr (s_upi_addr),
        .s_upi_din  (s_upi_din),
        .s_upi_dout (s_upi_dout),
        .cfg_vld    (reg2core_cfg_vld),
        .cfg_mode   (reg2core_cfg_mode),
        .cfg_klen   (reg2core_cfg_klen),
        .cfg_key    (reg2core_cfg_key),
        .cfg_busy   (core2reg_cfg_busy),
        .cfg_err    (core2reg_cfg_err),
        .cfg_rk_wr  (reg2core_cfg_rk_wr),
        .cfg_rk_idx (reg2core_cfg_rk_idx),
        .cfg_ldrdy  (core2reg_cfg_ldrdy),
        .cfg_rk_drop (core2reg_cfg_rk_drop),
        // din_valid and din_ready are DCNT monitor taps of the stream; din_ready is driven by icore only
        .din_valid  (din_valid),
        .din_ready  (din_ready)
    );

    // cfg_err pulses in the cycle cfg_busy falls, so ireg sets CSR.ERR and CSR.CFG_DONE on the same edge, unless a new CSR write followed the rejected one
    vb_mkv_core #(
        .DIR       (DIR),
        .TARGET    (TARGET),
        .SBOX_IMPL (SBOX_IMPL),
        .PROFILE   (PROFILE),
        .KEY_SCHED (KEY_SCHED),
        .RKS_IMPL  (RKS_IMPL),
        .RS_LV     (RS_LV),
        .BLOCK     (BLOCK),
        .DEC_ARCH  (DEC_ARCH)
    ) icore (
        .clk        (clk),
        .rst_n      (rst_n),
        .cfg_vld    (reg2core_cfg_vld),
        .cfg_mode   (reg2core_cfg_mode),
        .cfg_klen   (reg2core_cfg_klen),
        .cfg_key    (reg2core_cfg_key),
        .cfg_busy   (core2reg_cfg_busy),
        .cfg_err    (core2reg_cfg_err),
        .cfg_rk_wr  (reg2core_cfg_rk_wr),
        .cfg_rk_idx (reg2core_cfg_rk_idx),
        .cfg_ldrdy  (core2reg_cfg_ldrdy),
        .cfg_rk_drop (core2reg_cfg_rk_drop),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .din_data   (din_data),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready),
        .dout_data  (dout_data)
    );

endmodule

`default_nettype wire
