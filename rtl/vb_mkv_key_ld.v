`default_nettype none

// vb_mkv_key_ld : software round-key load window (v3, KEY_SCHED = "EXT"), replaces vb_mkv_key_exp
//   same contract towards the engine / vb_mkv_cfg (kx_start / kx_busy / kx_done / kx_mode / kx_rnd / kx_wk);
//   writes each validated UPI commit into the round-key store and completes when indices 0..2R are covered
//   (ddoc/vb_mkv_arch.md section 13, ddoc/vb_mkv_key_ld_req.md)
module vb_mkv_key_ld #(
    parameter DIR     = "BOTH",         //! mode forcing: "ENC" -> 0, "DEC" -> 1, "BOTH" -> cfg_mode
    parameter PROFILE = "TCVN2024",     //! "TCVN2024" (R = 6/7/8) | "IETF2026" (R = 7/8/9)
    parameter RS_LV   = 0               //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port (sampled at cfg_vld)
    input  wire         cfg_vld,        //! sample mode / KLEN, abort the load window
    input  wire         cfg_mode,       //! 0 = encrypt, 1 = decrypt
    input  wire [1:0]   cfg_klen,       //! 0/1/2 = 128/192/256 bit
    input  wire [255:0] cfg_key,        //! [255:128] = staging round key {MK0..MK3}, [127:0] unused

    // round-key commit (from vb_mkv_reg, already validated)
    input  wire         cfg_rk_wr,      //! 1-cycle commit pulse
    input  wire [4:0]   cfg_rk_idx,     //! store index of the commit

    // control / status towards vb_mkv_ctrl (same contract as vb_mkv_key_exp)
    input  wire         kx_start,       //! open the load window
    output wire         kx_busy,        //! load window open (also core cfg_ldrdy)
    output wire         kx_done,        //! pulse in the completing commit cycle
    output wire         kx_mode,        //! sampled DIR-forced mode
    output wire [3:0]   kx_rnd,         //! sampled number of rounds R
    output wire [127:0] kx_wk,          //! whitening key: K_0^0 (enc) / XW(K_post) (dec)

    // round-key store write port (lib vb_sdp_ram_pp irk_store in vb_mkv_core)
    output wire         mrk_st,         //! store write enable
    output wire [4:0]   mrk_waddr,      //! store index
    output wire [127:0] mrk_wdata,      //! round key

    // commit status towards vb_mkv_reg (vtrace T-5)
    output wire         kx_rk_drop      //! 1-cycle pulse: a cfg_rk_wr commit was not stored (-> CSR.ERR)
);

    /* verilator lint_off WIDTHEXPAND */
    localparam IS_IETF = (PROFILE == "IETF2026") ? 1'b1 : 1'b0;   // R = 7/8/9
    localparam DIR_ENC = (DIR == "ENC") ? 1'b1 : 1'b0;
    localparam DIR_DEC = (DIR == "DEC") ? 1'b1 : 1'b0;
    /* verilator lint_on WIDTHEXPAND */
    localparam MASK_W  = IS_IETF ? 19 : 17;                       // 2 * R_MAX + 1 store entries
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;              // 1-bit reset level

    //==========================================================================
    // functions
    //==========================================================================

    // R from the key-length code and PROFILE (KLEN = 3 is rejected by ctrl: don't care)
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

    // XWords: each 32-bit sub-state xored with the xor of all four sub-states
    function [127:0] f_xw;
        input [127:0] x;
        reg   [31:0]  sx;
        begin
            sx   = x[127:96] ^ x[95:64] ^ x[63:32] ^ x[31:0];
            f_xw = x ^ {sx, sx, sx, sx};
        end
    endfunction

    //==========================================================================
    // storage
    //==========================================================================

    reg               kl_busy_ff;       // load window open
    reg  [MASK_W-1:0] kl_mask_ff;       // indices committed since the window opened
    reg               kl_mode_ff;       // sampled DIR-forced mode
    reg  [3:0]        kl_rnd_ff;        // sampled R
    reg  [127:0]      wk_ff;            // whitening key

    //==========================================================================
    // commit decode
    //==========================================================================

    wire [4:0]        kl_idx_last = {kl_rnd_ff, 1'b0};                       // 2R = index of K_post
    wire              kl_commit   = cfg_rk_wr && kl_busy_ff && (cfg_rk_idx <= kl_idx_last);
    wire [127:0]      kl_key      = cfg_key[255:128];
    wire [127:0]      kl_key_xw   = f_xw(kl_key);                         // dec whitening key XW(K_post)

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    wire [MASK_W-1:0] kl_onehot   = {{(MASK_W-1){1'b0}}, 1'b1} << cfg_rk_idx;     // committed index
    wire [MASK_W-1:0] kl_need     = ~({MASK_W{1'b1}} << (kl_idx_last + 5'd1));    // bits 0 .. 2R
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
    wire [MASK_W-1:0] kl_cover    = kl_mask_ff | kl_onehot;
    wire              kl_done     = kl_commit && ((kl_cover & kl_need) == kl_need);

    // DIR-forced mode of a new request
    wire              kl_mode_nx  = DIR_ENC ? 1'b0 : (DIR_DEC ? 1'b1 : cfg_mode);

    //==========================================================================
    // load window, mask and sampled configuration
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            kl_busy_ff <= 1'b0;
            kl_mask_ff <= {MASK_W{1'b0}};
            kl_mode_ff <= 1'b0;
            kl_rnd_ff  <= 4'd0;
        end else if (cfg_vld) begin
            // abort / restart (OP-6): close the window, sample the new request
            kl_busy_ff <= 1'b0;
            kl_mask_ff <= {MASK_W{1'b0}};
            kl_mode_ff <= kl_mode_nx;
            kl_rnd_ff  <= f_rnd(cfg_klen);
        end else if (kx_start) begin
            kl_busy_ff <= 1'b1;
            kl_mask_ff <= {MASK_W{1'b0}};
        end else if (kl_commit) begin
            kl_mask_ff <= kl_cover;
            if (kl_done) begin
                kl_busy_ff <= 1'b0;
            end
        end
    end

    //==========================================================================
    // whitening key: enc K_0^0 (index 0), dec XW(K_post) (index 2R)
    //==========================================================================

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            wk_ff <= 128'd0;
        end else if (kl_commit && (!cfg_vld) && (!kx_start)) begin
            if ((!kl_mode_ff) && (cfg_rk_idx == 5'd0)) begin
                wk_ff <= kl_key;
            end else if (kl_mode_ff && (cfg_rk_idx == kl_idx_last)) begin
                wk_ff <= kl_key_xw;
            end
        end
    end

    //==========================================================================
    // outputs
    //==========================================================================

    assign kx_busy   = kl_busy_ff;
    assign kx_done   = kl_done && (!cfg_vld) && (!kx_start);
    assign kx_mode   = kl_mode_ff;
    assign kx_rnd    = kl_rnd_ff;
    assign kx_wk     = wk_ff;

    assign mrk_st    = kl_commit && (!cfg_vld) && (!kx_start);
    // every commit pulse that is not stored is reported (window closed, e.g. one cycle after the
    // completing commit, index above 2R, or a cfg_vld / kx_start collision)
    assign kx_rk_drop = cfg_rk_wr && (!mrk_st);
    assign mrk_waddr = cfg_rk_idx;
    assign mrk_wdata = kl_key;

    // cfg_key[127:0] is the INT key half, unused in EXT
    /* verilator lint_off UNUSEDSIGNAL */
    wire [127:0] unused_key_lo = cfg_key[127:0];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
