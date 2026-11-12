`default_nettype none

// vb_mkv_cfg : configure-port protocol of vb_mkv (v4, arch section 14.6), shared by vb_mkv_eng_a / vb_mkv_eng_t
//   = v3 vb_mkv_ctrl section A verbatim (config FSM C_NOKEY / C_REJ / C_PEND / C_KS / C_READY, P-A6, OP-4/6/7),
//   with the v3 "engine IDLE" condition as the input eng_idle
module vb_mkv_cfg #(
    parameter DIR   = "BOTH",           //! "ENC" -> mode 0, "DEC" -> mode 1, "BOTH" -> kx_mode
    parameter RS_LV = 0                 //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port
    input  wire         cfg_vld,        //! start / restart request (pulse)
    input  wire [1:0]   cfg_klen,       //! key length code, 3 = invalid (validation only)
    output wire         cfg_busy,       //! request validating / pending / running (registered state)
    output wire         cfg_err,        //! reject pulse, in the cfg_busy fall cycle unless a new cfg_vld followed (P-A6)

    // key source (INT key schedule, or EXT load window [+ engine-T conversion])
    output wire         kx_start,       //! start the key source: C_PEND and engine idle and no cfg_vld
    input  wire         kx_busy,        //! key source busy (contract: high exactly in C_KS; observed by SVA only)
    input  wire         kx_done,        //! key source done, last busy cycle
    input  wire         kx_mode,        //! mode of the request
    input  wire [3:0]   kx_rnd,         //! R of the request

    // engine
    input  wire         eng_idle,       //! no block in flight (an output held in the output register may remain)
    output wire         key_valid,      //! key loaded, streaming allowed (C_READY)
    output wire         act_mode,       //! DIR-forced mode latched at kx_done
    output wire [3:0]   act_rnd         //! R latched at kx_done
);

    localparam C_NOKEY = 3'd0;          // no usable key
    localparam C_REJ   = 3'd1;          // invalid request being rejected (1 cycle)
    localparam C_PEND  = 3'd2;          // valid request waiting for the engine to drain
    localparam C_KS    = 3'd3;          // key source running
    localparam C_READY = 3'd4;          // key loaded, streaming allowed

    localparam KLEN_BAD = 2'd3;         // invalid key-length code
    localparam RS_ACT   = (RS_LV != 0) ? 1'b1 : 1'b0;   // 1-bit reset level

    /* verilator lint_off WIDTHEXPAND */
    localparam DIR_ENC  = (DIR == "ENC") ? 1'b1 : 1'b0;
    localparam DIR_DEC  = (DIR == "DEC") ? 1'b1 : 1'b0;
    /* verilator lint_on WIDTHEXPAND */

    //==========================================================================
    // configuration FSM (pending / drain / restart / reject)
    //==========================================================================

    reg  [2:0]   cfg_state_ff;
    reg  [2:0]   cfg_state_ns;

    wire         klen_bad   = (cfg_klen == KLEN_BAD);
    wire         st_rej     = (cfg_state_ff == C_REJ);
    wire         st_pend    = (cfg_state_ff == C_PEND);
    wire         st_ks      = (cfg_state_ff == C_KS);

    always @* begin
        cfg_state_ns = cfg_state_ff;
        if (cfg_vld) begin
            cfg_state_ns = klen_bad ? C_REJ : C_PEND;
        end else begin
            case (cfg_state_ff)
                C_NOKEY : cfg_state_ns = C_NOKEY;
                C_REJ   : cfg_state_ns = C_NOKEY;
                C_PEND  : cfg_state_ns = eng_idle ? C_KS : C_PEND;
                C_KS    : cfg_state_ns = kx_done ? C_READY : C_KS;
                C_READY : cfg_state_ns = C_READY;
                default : cfg_state_ns = C_NOKEY;
            endcase // cfg_state_ff
        end
    end

    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            cfg_state_ff    <= C_NOKEY;
        end else begin
            cfg_state_ff    <= cfg_state_ns;
        end
    end

    // reject pulse: registered from C_REJ, lands in the first cfg_busy = 0 cycle (or with a new cfg_vld)
    reg          err_ff;
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            err_ff  <= 1'b0;
        end else begin
            err_ff  <= st_rej;
        end
    end

    //==========================================================================
    // active mode / R of the loaded key (DIR-forced)
    //==========================================================================

    wire         kx_mode_f  = DIR_ENC ? 1'b0
                            : DIR_DEC ? 1'b1
                            :           kx_mode
                            ;
    reg          act_mode_ff;
    reg  [3:0]   act_rnd_ff;
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            act_mode_ff <= 1'b0;
            act_rnd_ff  <= 4'd0;
        end else if (st_ks & kx_done) begin
            act_mode_ff <= kx_mode_f;
            act_rnd_ff  <= kx_rnd;
        end
    end

    //==========================================================================
    // outputs
    //==========================================================================

    assign kx_start  = st_pend & eng_idle & ~cfg_vld;
    assign cfg_busy  = st_rej | st_pend | st_ks;
    assign cfg_err   = err_ff;
    assign key_valid = (cfg_state_ff == C_READY);
    assign act_mode  = act_mode_ff;
    assign act_rnd   = act_rnd_ff;

    // kx_busy is part of the contract (high exactly in C_KS) and checked by SVA; the FSM needs only kx_done
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_kx_busy = kx_busy;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
