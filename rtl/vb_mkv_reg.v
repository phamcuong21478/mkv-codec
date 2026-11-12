`default_nettype none

// vb_mkv_reg : UPI register file of vb_mkv (spec 7.4, LSN-3: semantics identical to vb_sm4_reg)
//   v5 (arch §15.8 / §15.13): BLOCK = 128 | 256. BLOCK=128 keeps the v4 map, widths and logic (only INFO[7:0]
//   changes, VERSION 0x04 for every build); BLOCK=256 adds a 5-bit address, MK8..MK15 at 0x10..0x17 (generate
//   block g_mk256), cfg_key {MK0..MK15} and INFO[14] = 1.
module vb_mkv_reg #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH": MODE writability, INFO[9:8]
    /* verilator lint_off UNUSEDPARAM */
    parameter TARGET    = "FPGA",       //! "FPGA" | "ASIC": INFO[12] (v2)
    /* verilator lint_on UNUSEDPARAM */
    parameter SBOX_IMPL = (TARGET == "ASIC") ? "LOGIC" : "BRAM",  //! "BRAM" | "LOGIC" | "LUT" (alias): INFO[10] = BRAM
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" | "IETF2026": INFO[11], R for LAT
    parameter KEY_SCHED = "INT",        //! "INT" | "EXT" (v3): EXT adds RKIDX at 0xC, upper MK half reserved, INFO[13]
    parameter RS_LV     = 0,            //! reset active level (0 = active-low)
    parameter BLOCK     = 128           //! 128 | 256 (v5): address width, MK word count, INFO[14]
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // UPI CPU register bus (slave)
    input  wire         s_upi_we,       //! write strobe (one write per cycle high)
    input  wire         s_upi_oe,       //! read strobe
    input  wire [((BLOCK == 256) ? 5 : 4)-1:0] s_upi_addr,  //! word address (not latched; 5 bit for BLOCK=256)
    input  wire [31:0]  s_upi_din,      //! write data
    output wire [31:0]  s_upi_dout,     //! read data, 1 cycle after s_upi_oe, held

    // configure port (to vb_mkv_core)
    output wire         cfg_vld,        //! 1-cycle pulse after any CSR write
    output wire         cfg_mode,       //! DIR-forced CSR.MODE
    output wire [1:0]   cfg_klen,       //! CSR.KLEN
    output wire [2*BLOCK-1:0] cfg_key,  //! {MK0..MK7} (BLOCK=256: {MK0..MK15}), MK0 in the MS word
    input  wire         cfg_busy,       //! core busy level
    input  wire         cfg_err,        //! core reject pulse (busy fall cycle unless a new request followed)

    // stream monitor (DCNT)
    input  wire         din_valid,      //! input block valid
    input  wire         din_ready,      //! input block ready

    // round-key load port (v3, KEY_SCHED = "EXT"; constant 0 / unused in INT)
    output wire         cfg_rk_wr,      //! 1-cycle commit pulse for a validated RKIDX write
    output wire [4:0]   cfg_rk_idx,     //! RKIDX.IDX, valid with cfg_rk_wr
    input  wire         cfg_ldrdy,      //! core load window open (RKIDX.LDRDY)
    input  wire         cfg_rk_drop     //! core dropped a forwarded commit (1-cycle) -> CSR.ERR (vtrace T-5)
);

    // v5: UPI address width (4 for BLOCK=128 = v4, 5 for BLOCK=256); addresses sized to it
    localparam UPI_AW    = (BLOCK == 256) ? 5 : 4;
    localparam [UPI_AW-1:0] ADDR_CSR  = 'h0;        // control / status
    localparam [UPI_AW-1:0] ADDR_DCNT = 'h1;        // accepted-block counter
    localparam [UPI_AW-1:0] ADDR_INFO = 'h2;        // build information
    localparam [UPI_AW-1:0] ADDR_LAT  = 'h3;        // cycle figures of the loaded key
    localparam [UPI_AW-1:0] ADDR_MK0  = 'h4;        // MK0 .. MK7 at 0x4 .. 0xB
    localparam [UPI_AW-1:0] ADDR_MK1  = 'h5;
    localparam [UPI_AW-1:0] ADDR_MK2  = 'h6;
    localparam [UPI_AW-1:0] ADDR_MK3  = 'h7;
    localparam [UPI_AW-1:0] ADDR_MK4  = 'h8;
    localparam [UPI_AW-1:0] ADDR_MK5  = 'h9;
    localparam [UPI_AW-1:0] ADDR_MK6  = 'hA;
    localparam [UPI_AW-1:0] ADDR_MK7  = 'hB;
    localparam [UPI_AW-1:0] ADDR_RKIDX = 'hC;       // v3 EXT: round-key commit index / LDRDY
    localparam VERSION   = 8'h04;       // INFO[7:0] (v5: 0x04 for every build, Q4; v4 was 0x03)

    // v2: INFO[12] = TARGET (1 = ASIC), INFO[10] = 1 only for BRAM (LOGIC and the LUT alias read 0),
    // reserved bits 31:13
    // v3: INFO[13] = KEY_SCHED (1 = EXT); EXT: RKIDX at 0xC, MK4..MK7 reserved (read 0, no storage)
    // v5: INFO[14] = BLOCK (1 = 256); BLOCK=256: MK8..MK15 at 0x10..0x17 (EXT: reserved, staging MK0..MK7),
    //     0xD..0xF and 0x18..0x1F reserved

    // parameter decode (string compares width-mismatch when overridden)
    /* verilator lint_off WIDTHEXPAND */
    localparam       DIR_ENC     = (DIR == "ENC")       ? 1'b1 : 1'b0;
    localparam       DIR_DEC     = (DIR == "DEC")       ? 1'b1 : 1'b0;
    localparam       SBOX_BIT    = (SBOX_IMPL == "BRAM") ? 1'b1 : 1'b0;   // INFO[10]
    localparam       PROFILE_BIT = (PROFILE == "IETF2026") ? 1'b1 : 1'b0; // INFO[11]
    localparam       TARGET_BIT  = (TARGET == "ASIC") ? 1'b1 : 1'b0;      // INFO[12] (v2)
    localparam       IS_EXT      = (KEY_SCHED == "EXT") ? 1'b1 : 1'b0;   // INFO[13] (v3)
    localparam       BLOCK_BIT   = (BLOCK == 256) ? 1'b1 : 1'b0;         // INFO[14] (v5)
    /* verilator lint_on WIDTHEXPAND */
    localparam       DIR_BOTH    = (!DIR_ENC) && (!DIR_DEC);
    localparam [1:0] DIR_CODE    = DIR_ENC ? 2'd0 : (DIR_DEC ? 2'd1 : 2'd2);  // INFO[9:8]
    localparam       RS_ACT      = (RS_LV != 0) ? 1'b1 : 1'b0;   // 1-bit reset level

    //==========================================================================
    // storage
    //==========================================================================
    reg             rf_mode_ff;         // CSR.MODE (used for DIR = BOTH)
    reg  [1:0]      rf_klen_ff;         // CSR.KLEN
    reg             rf_done_ff;         // CSR.CFG_DONE, sticky RC
    reg             rf_err_ff;          // CSR.ERR, sticky RC
    reg  [31:0]     rf_dcnt_ff;         // DCNT, RC counter
    reg  [31:0]     rf_mk0_ff;          // MK0 (cfg_key[255:224])
    reg  [31:0]     rf_mk1_ff;
    reg  [31:0]     rf_mk2_ff;
    reg  [31:0]     rf_mk3_ff;
    reg  [31:0]     rf_mk4_ff;
    reg  [31:0]     rf_mk5_ff;
    reg  [31:0]     rf_mk6_ff;
    reg  [31:0]     rf_mk7_ff;          // MK7 (cfg_key[31:0])
    reg  [3:0]      rf_lat_rnd_ff;      // R of the loaded key, 0 = no key
    reg             rf_cfg_vld_ff;      // cfg_vld pulse
    reg             rf_busy_ff;         // cfg_busy history (falling-edge detect)
    reg  [31:0]     upi_rdata_ff;       // registered read data
    reg  [4:0]      rf_rkidx_ff;        // v3 EXT: RKIDX.IDX (stays 0 in INT)
    reg             rf_rk_wr_ff;        // v3 EXT: cfg_rk_wr pulse (stays 0 in INT)

    //==========================================================================
    // address decode
    //==========================================================================

    // decode CSR write, MK0 to MK7 writes, CSR read and DCNT read strobes
    wire up_wr_csr  = s_upi_we && (s_upi_addr == ADDR_CSR);
    wire up_rd_csr  = s_upi_oe && (s_upi_addr == ADDR_CSR);
    wire up_rd_dcnt = s_upi_oe && (s_upi_addr == ADDR_DCNT);

    // busy falling edge and accepted-block event
    wire busy_fall  = (!cfg_busy) && rf_busy_ff;
    wire dcnt_ev    = din_valid && din_ready;

    // v3 EXT: RKIDX commit validation (driven in the round-key load section below)
    wire up_wr_rkidx;           // RKIDX write strobe (EXT only)
    wire rk_acc;                // commit accepted
    wire rk_rej;                // commit rejected -> ERR
    wire rk_drop = IS_EXT && cfg_rk_drop;   // forwarded commit not stored by the core -> ERR (EXT only)

    // v3 EXT: MK4..MK7 writes only in INT (EXT: reserved, registers stay 0 and are removed by synthesis)
    // v5: the reserved EXT half is the upper half of the MK words: MK4..MK7 for BLOCK=128 (v4), MK8..MK15 for
    //     BLOCK=256 (MK4..MK7 then belong to the 256-bit staging window and are always writable)
    wire up_mk_hi_en = !IS_EXT;
    wire up_mk47_en  = (BLOCK == 256) ? 1'b1 : up_mk_hi_en;    // = up_mk_hi_en for BLOCK=128

    // v4 INT MK lock (REQ-V4-8): from the cfg_vld cycle of a CSR write until cfg_busy falls the master key
    // is read by the engine's key schedule; an MK0..MK7 write is ignored and sets ERR (EXT: no lock)
    wire up_wr_mkh;             // v5 BLOCK=256: MK8..MK15 write strobe (0 for BLOCK=128, g_mk256 below)
    wire up_wr_mk  = (s_upi_we && (s_upi_addr >= ADDR_MK0) && (s_upi_addr <= ADDR_MK7)) || up_wr_mkh;
    wire mk_lock   = (!IS_EXT) && (cfg_busy || rf_cfg_vld_ff);
    wire mk_rej    = up_wr_mk && mk_lock;
    wire up_mk_en  = !mk_lock;

    //==========================================================================
    // writable registers (CSR.MODE / CSR.KLEN / MK0..MK7) and cfg_vld
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            rf_mode_ff    <= 1'b0;
            rf_klen_ff    <= 2'd0;
            rf_mk0_ff     <= 32'd0;
            rf_mk1_ff     <= 32'd0;
            rf_mk2_ff     <= 32'd0;
            rf_mk3_ff     <= 32'd0;
            rf_mk4_ff     <= 32'd0;
            rf_mk5_ff     <= 32'd0;
            rf_mk6_ff     <= 32'd0;
            rf_mk7_ff     <= 32'd0;
            rf_cfg_vld_ff <= 1'b0;
            rf_busy_ff    <= 1'b0;
        end else begin
            // CSR / MKx writes: one write per s_upi_we cycle
            if (s_upi_we) begin
                case (s_upi_addr)
                    ADDR_CSR: begin
                        rf_klen_ff <= s_upi_din[3:2];
                        if (DIR_BOTH) begin
                            rf_mode_ff <= s_upi_din[0];
                        end
                    end
                    ADDR_MK0: if (up_mk_en) rf_mk0_ff <= s_upi_din;
                    ADDR_MK1: if (up_mk_en) rf_mk1_ff <= s_upi_din;
                    ADDR_MK2: if (up_mk_en) rf_mk2_ff <= s_upi_din;
                    ADDR_MK3: if (up_mk_en) rf_mk3_ff <= s_upi_din;
                    ADDR_MK4: if (up_mk47_en && up_mk_en) rf_mk4_ff <= s_upi_din;
                    ADDR_MK5: if (up_mk47_en && up_mk_en) rf_mk5_ff <= s_upi_din;
                    ADDR_MK6: if (up_mk47_en && up_mk_en) rf_mk6_ff <= s_upi_din;
                    ADDR_MK7: if (up_mk47_en && up_mk_en) rf_mk7_ff <= s_upi_din;
                    default: begin end
                endcase
            end

            // cfg_vld pulse in the cycle after any CSR write, busy history
            rf_cfg_vld_ff <= up_wr_csr;
            rf_busy_ff    <= cfg_busy;
        end
    end

    //==========================================================================
    // sticky status (CFG_DONE / ERR), set over read-clear
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            rf_done_ff <= 1'b0;
            rf_err_ff  <= 1'b0;
        end else begin
            if (busy_fall) begin
                rf_done_ff <= 1'b1;
            end else if (up_rd_csr) begin
                rf_done_ff <= 1'b0;
            end

            if (cfg_err || rk_rej || rk_drop || mk_rej) begin // v3 rk reject/drop, v4 INT MK-lock write
                rf_err_ff <= 1'b1;
            end else if (up_rd_csr) begin
                rf_err_ff <= 1'b0;
            end
        end
    end

    //==========================================================================
    // DCNT read-to-clear counter
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            rf_dcnt_ff <= 32'd0;
        end else begin
            if (up_rd_dcnt) begin
                // read latches the old value; restart counting this cycle's event
                rf_dcnt_ff <= dcnt_ev ? 32'd1 : 32'd0;
            end else if (dcnt_ev) begin
                rf_dcnt_ff <= rf_dcnt_ff + 32'd1;
            end
        end
    end

    //==========================================================================
    // LAT (R of the loaded key)
    //==========================================================================

    // R from the key-length code and PROFILE: TCVN2024 6/7/8, IETF2026 7/8/9, code 3 gives 0
    function [3:0] f_rnd;
        input [1:0] klen;
        input       prof;
        begin
            case (klen)
                2'd0:    f_rnd = prof ? 4'd7 : 4'd6;
                2'd1:    f_rnd = prof ? 4'd8 : 4'd7;
                2'd2:    f_rnd = prof ? 4'd9 : 4'd8;
                default: f_rnd = 4'd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            rf_lat_rnd_ff <= 4'd0;
        end else begin
            if (rf_cfg_vld_ff) begin
                rf_lat_rnd_ff <= 4'd0;              // new request: no key
            end else if (cfg_err) begin
                rf_lat_rnd_ff <= 4'd0;              // rejected request: no key
            end else if (busy_fall) begin
                rf_lat_rnd_ff <= f_rnd(rf_klen_ff, PROFILE_BIT);
            end
        end
    end

    //==========================================================================
    // round-key load port (v3, KEY_SCHED = "EXT")
    //==========================================================================
    // a write to RKIDX in cycle w is accepted iff the core load window is open, no cfg_vld is in
    // flight (a CSR write in w-1 restarts the window) and IDX <= 2R of the current CSR.KLEN;
    // accepted -> cfg_rk_wr pulse in w+1 with cfg_rk_idx = IDX, rejected -> ERR (sticky RC)

    wire [4:0] rk_idx_max = {f_rnd(rf_klen_ff, PROFILE_BIT), 1'b0};  // 2R (0 for KLEN = 3)
    assign up_wr_rkidx = IS_EXT && s_upi_we && (s_upi_addr == ADDR_RKIDX);
    assign rk_acc      = up_wr_rkidx && cfg_ldrdy && (!rf_cfg_vld_ff) && (s_upi_din[4:0] <= rk_idx_max);
    assign rk_rej      = up_wr_rkidx && (!rk_acc);

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            rf_rkidx_ff <= 5'd0;
            rf_rk_wr_ff <= 1'b0;
        end else begin
            if (up_wr_rkidx) begin
                rf_rkidx_ff <= s_upi_din[4:0];
            end
            rf_rk_wr_ff <= rk_acc;
        end
    end

    // RKIDX read word: [4:0] IDX, [8] LDRDY (level, no read side effect); INT: reserved 0
    wire [31:0] rkidx_word = IS_EXT ? {23'd0, cfg_ldrdy, 3'd0, rf_rkidx_ff} : 32'd0;

    assign cfg_rk_wr  = rf_rk_wr_ff;
    assign cfg_rk_idx = rf_rkidx_ff;

    // LAT word: R in [3:0], 2R in [15:8], 2R+1 in [23:16] (v4); all zero when R = 0
    // v4: cycles per block 2R, latency 2R+1 (REQ-V4-1/9)
    wire [7:0]  lat_cpb = {3'd0, rf_lat_rnd_ff, 1'b0};
    wire [7:0]  lat_lat = (rf_lat_rnd_ff == 4'd0) ? 8'd0 : (lat_cpb + 8'd1);
    wire [31:0] lat_word = {8'd0, lat_lat, lat_cpb, 4'd0, rf_lat_rnd_ff};

    //==========================================================================
    // read path
    //==========================================================================

    // DIR-forced mode: ENC 0, DEC 1, BOTH rf_mode_ff
    wire        mode_rd   = DIR_ENC ? 1'b0 : (DIR_DEC ? 1'b1 : rf_mode_ff);
    wire [31:0] csr_word  = {27'd0, rf_err_ff, rf_klen_ff, rf_done_ff, mode_rd};
    wire [31:0] info_word = {17'd0, BLOCK_BIT, IS_EXT, TARGET_BIT, PROFILE_BIT, SBOX_BIT, DIR_CODE, VERSION};
    wire [31:0] mkh_rdata;      // v5 BLOCK=256: MK8..MK15 read word, 0 elsewhere (constant 0 for BLOCK=128)

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            upi_rdata_ff <= 32'd0;
        end else begin
            if (s_upi_oe) begin
                case (s_upi_addr)
                    ADDR_CSR:  upi_rdata_ff <= csr_word;
                    ADDR_DCNT: upi_rdata_ff <= rf_dcnt_ff;
                    ADDR_INFO: upi_rdata_ff <= info_word;
                    ADDR_LAT:  upi_rdata_ff <= lat_word;
                    ADDR_MK0:  upi_rdata_ff <= rf_mk0_ff;
                    ADDR_MK1:  upi_rdata_ff <= rf_mk1_ff;
                    ADDR_MK2:  upi_rdata_ff <= rf_mk2_ff;
                    ADDR_MK3:  upi_rdata_ff <= rf_mk3_ff;
                    ADDR_MK4:  upi_rdata_ff <= rf_mk4_ff;
                    ADDR_MK5:  upi_rdata_ff <= rf_mk5_ff;
                    ADDR_MK6:  upi_rdata_ff <= rf_mk6_ff;
                    ADDR_MK7:  upi_rdata_ff <= rf_mk7_ff;
                    ADDR_RKIDX: upi_rdata_ff <= rkidx_word; // v3 EXT (INT: 0)
                    default:   upi_rdata_ff <= mkh_rdata; // reserved 0xD..0xF (0xC in INT) read 0; v5 0x10..0x17 MK8..MK15
                endcase
            end
        end
    end

    assign s_upi_dout = upi_rdata_ff;

    //==========================================================================
    // configure port outputs
    //==========================================================================

    assign cfg_vld  = rf_cfg_vld_ff;
    assign cfg_klen = rf_klen_ff;
    assign cfg_mode = mode_rd;

    //==========================================================================
    // v5: MK8..MK15 (BLOCK=256 only) and cfg_key assembly
    //==========================================================================
    // BLOCK=128: no MK8..MK15 storage, the strobe and the read word are constant 0 and cfg_key is the v4
    // concatenation. BLOCK=256: MK8..MK15 at 0x10..0x17 (INT: key words 8..15, same MK lock and ERR as
    // MK0..MK7; EXT: reserved, writes ignored, read 0, cfg_key[255:0] = 0).
    generate
        if (BLOCK == 256) begin : g_mk256
            reg  [31:0] rf_mkh_ff [0:7];        // MK8 .. MK15 (MK15 = cfg_key[31:0])
            wire        mkh_sel = (s_upi_addr[UPI_AW-1 -: 2] == 2'b10);    // 0x10..0x17
            integer     i;
            assign up_wr_mkh = s_upi_we && mkh_sel;

            always @(posedge clk) begin
                if (rst_n == RS_ACT) begin
                    for (i = 0; i < 8; i = i + 1) begin
                        rf_mkh_ff[i] <= 32'd0;
                    end
                end else begin
                    if (up_wr_mkh && up_mk_hi_en && up_mk_en) begin
                        rf_mkh_ff[s_upi_addr[2:0]] <= s_upi_din;
                    end
                end
            end

            assign mkh_rdata = mkh_sel ? rf_mkh_ff[s_upi_addr[2:0]] : 32'd0;
            assign cfg_key   = {rf_mk0_ff, rf_mk1_ff, rf_mk2_ff, rf_mk3_ff,
                                rf_mk4_ff, rf_mk5_ff, rf_mk6_ff, rf_mk7_ff,
                                rf_mkh_ff[0], rf_mkh_ff[1], rf_mkh_ff[2], rf_mkh_ff[3],
                                rf_mkh_ff[4], rf_mkh_ff[5], rf_mkh_ff[6], rf_mkh_ff[7]};
        end else begin : g_mk128
            assign up_wr_mkh = 1'b0;
            assign mkh_rdata = 32'd0;
            assign cfg_key   = {rf_mk0_ff, rf_mk1_ff, rf_mk2_ff, rf_mk3_ff,
                                rf_mk4_ff, rf_mk5_ff, rf_mk6_ff, rf_mk7_ff};
        end
    endgenerate

endmodule

`default_nettype wire
