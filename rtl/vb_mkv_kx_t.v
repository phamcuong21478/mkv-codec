`default_nettype none

// vb_mkv_kx_t : engine-T key source (vb_mkv_eng_t, arch v4 section 14.2): INT key schedule on the T-box datapath
//   and the round-key store format conversion (INT and EXT). Engine-private store image (consumption order,
//   identical index use for ENC and DEC; whitening key wk and output key kp in registers):
//     ENC: idx 2r+1 = T(K_r^1) (byte transpose), idx 2r = K_r^0 (r >= 1); wk = K_0^0, kp = K_post
//     DEC: idx 2j+1 = T(M4^-1(K_{R-1-j}^1)), idx 2j+2 = XW(K_{R-1-j}^0) (j < R-1); wk = XW(K_post), kp = K_0^0
//   INT (spec 3.5): INIT0 kp <= R0, INIT1 kt <= R0 ^ <2> and kp <= L0, then s = 0 .. 8R-1, 8 cycles per UpdateKS i:
//     u = 0..3 chain L_i = F0(F0(R_{i-1} ^ <2i>)), u = 4..7 chain T_i = F0(F0(L_{i-1} ^ <2i-1>)); F0 = T then XW
//     lookup with zero key. The address bus carries the chain: at u = 0 (i >= 2) it is T_{i-1} ^ L_{i-1} ^ <2i>
//     = R_{i-1} ^ <2i>. tap_ff takes L_i (u = 4) and R_{i-1} = XOR4 ^ kp (u = 0), kp_ff holds L (u = 5).
//     s = 8R taps R_R. ENC ends at s = 8R+1; DEC continues with the conversion pass.
//   Conversion pass (DEC, INT and EXT): every K1 entry T(K) -> T(M4^-1(K)): lookup 1 at address T(K) = rk in
//     half XW (-> XW(S(K))), tap XW (-> S(K)), lookup 2 at address tap in half T^-1 (-> T(M4^-1(K))), tap, write
//     back. Pair-interleaved: key j starts at k = 4*(j/2) + (j%2), read at k-1, write at k+4.
//   EXT: vb_mkv_key_ld commits are converted on the store write path (private index = raw (ENC) / 2R - raw
//     (DEC); odd raw -> T(), DEC even raw -> XW()); kp captured from the commit of raw 2R (ENC) / 0 (DEC).
//     The pass starts in the key_ld completing-commit cycle (k = -1). ENC / BOTH-enc: kx_done 1 cycle after.
module vb_mkv_kx_t #(
    parameter DIR       = "BOTH",       //! "ENC" | "DEC" | "BOTH"
    parameter PROFILE   = "TCVN2024",   //! "TCVN2024" (R 6/7/8) | "IETF2026" (R 7/8/9)
    parameter KEY_SCHED = "INT",        //! "INT": on-chip key schedule; "EXT": key_ld + conversion
    parameter RS_LV     = 0             //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV

    // configure port
    input  wire         cfg_vld,        //! request strobe: sample mode / KLEN (INT), abort
    input  wire         cfg_mode,       //! 0 encrypt, 1 decrypt (sampled at cfg_vld, INT)
    input  wire [1:0]   cfg_klen,       //! key length code (sampled at cfg_vld, INT)
    input  wire [255:0] cfg_key,        //! INT: master key {MK0..MK7}, stable while cfg_busy (reg MK lock)
    input  wire         kx_start,       //! start the key source (vb_mkv_cfg)

    // EXT: vb_mkv_key_ld
    input  wire         kl_busy,        //! load window open
    input  wire         kl_done,        //! completing commit cycle
    input  wire         kl_mode,        //! sampled DIR-forced mode
    input  wire [3:0]   kl_rnd,         //! sampled R
    input  wire         kl_st,          //! commit write
    input  wire [4:0]   kl_waddr,       //! commit index (v3 raw index)
    input  wire [127:0] kl_wdata,       //! commit key (raw)
    input  wire [127:0] kl_wk,          //! key_ld whitening key: K_0^0 (enc) / XW(K_post) (dec)

    // key source status (vb_mkv_cfg)
    output wire         kx_busy,        //! high from the cycle after kx_start to kx_done (C_KS)
    output wire         kx_done,        //! last busy cycle
    output wire         kx_mode,        //! mode of the request
    output wire [3:0]   kx_rnd,         //! R of the request

    // datapath (vb_mkv_round_t) while kx_t owns it
    input  wire [127:0] tap,            //! tap_ff
    output wire         own,            //! kx_t drives store read / BRAM enable / kt this cycle
    output wire         own_nx,         //! kx_t drives the lookup controls of the next cycle
    output wire         gate_nx,        //! next-cycle lookup controls
    output wire [1:0]   asel_nx,
    output wire [1:0]   hs_nx,
    output wire         tsel_nx,
    output wire         xws_nx,
    output wire         ben,            //! BRAM read enable this cycle
    output wire         kt_sel_kp,      //! kt_ff <= kp_ff ^ ctr
    output wire         kt_sel_zero,    //! kt_ff <= 0
    output wire [4:0]   ctr,            //! counter <i>
    output wire         kp_ce,          //! kp_ff load
    output wire         kp_sel_in,      //! kp_ff <= kp_in (1) / tap (0)
    output wire [127:0] kp_in,          //! kp_ff value
    output wire         tap_ce,         //! tap_ff load
    output wire [4:0]   raddr,          //! store read address (when own)
    output wire [127:0] wk,             //! whitening key

    // round-key store write port
    output wire         st,             //! store write enable
    output wire [4:0]   waddr,          //! store index (engine-private)
    output wire [127:0] wdata           //! store data (engine-private format)
);

    /* verilator lint_off WIDTHEXPAND */
    localparam HAS_DEC = (DIR != "ENC") ? 1 : 0;
    localparam DIR_DEC = (DIR == "DEC") ? 1 : 0;
    localparam DIR_ENC = (DIR == "ENC") ? 1 : 0;
    localparam IS_INT  = (KEY_SCHED == "INT") ? 1 : 0;
    localparam IS_IETF = (PROFILE == "IETF2026") ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;
    localparam [1:0] OP_RAW = 2'd0;     // store data op: raw
    localparam [1:0] OP_TR  = 2'd1;     //                byte transpose
    localparam [1:0] OP_XW  = 2'd2;     //                XWords

    //==========================================================================
    // functions
    //==========================================================================

    function [3:0] f_rnd;
        input [1:0] k;
        begin
            case (k)
                2'd1:    f_rnd = IS_IETF ? 4'd8 : 4'd7;
                2'd2:    f_rnd = IS_IETF ? 4'd9 : 4'd8;
                default: f_rnd = IS_IETF ? 4'd7 : 4'd6;
            endcase
        end
    endfunction

    function [127:0] f_xw;
        input [127:0] x;
        reg   [31:0]  s;
        begin
            s    = x[127:96] ^ x[95:64] ^ x[63:32] ^ x[31:0];
            f_xw = x ^ {s, s, s, s};
        end
    endfunction

    // byte transpose: out byte 4x+y = in byte 4y+x
    function [127:0] f_tr;
        input [127:0] x;
        integer n;
        begin
            for (n = 0; n < 16; n = n + 1) begin
                f_tr[127 - 8 * n -: 8] = x[127 - 8 * (4 * (n % 4) + n / 4) -: 8];
            end
        end
    endfunction

    function [127:0] f_op;
        input [1:0]   op;
        input [127:0] x;
        begin
            case (op)
                OP_TR:   f_op = f_tr(x);
                OP_XW:   f_op = f_xw(x);
                default: f_op = x;
            endcase
        end
    endfunction

    // conversion pass, cycle pk = k + 1 (pk >= 0): {rd_v, rd_j[3:0], lk_v, lk2, xws, wr_v, wr_j[3:0]}
    function [12:0] f_pass;
        input [7:0] pk;
        input [3:0] rn;
        reg   [6:0] kk;
        reg   [4:0] m;
        reg   [1:0] q;
        reg   [5:0] jr, jl, jw;
        reg         rv, lv, l2, xw, wv;
        begin
            // read for the key whose lookup 1 is at k = pk
            m  = pk[6:2];
            q  = pk[1:0];
            jr = {m, 1'b0} + {5'd0, q[0]};
            rv = ~q[1] & (jr < {2'b0, rn});
            // lookup / tap / write at k = pk - 1
            kk = pk[6:0] - 7'd1;
            m  = kk[6:2];
            q  = kk[1:0];
            l2 = q[1];                                          // q 0/1: lookup 1, q 2/3: lookup 2
            jl = {m, 1'b0} + {5'd0, q[0]};
            lv = (pk != 8'd0) & (jl < {2'b0, rn});
            xw = (q == 2'd1) | (q == 2'd2);                     // tap of a lookup-1 result
            jw = {m, 1'b0} - 6'd2 + {5'd0, q[0]};
            wv = (pk >= 8'd5) & ~q[1] & (jw < {2'b0, rn});
            f_pass = {rv, jr[3:0], lv, l2, xw, wv, jw[3:0]};
        end
    endfunction

    // last pass cycle pk: k_last + 1 = 4*((R-1)/2) + ((R-1)%2) + 5
    function [7:0] f_pk_last;
        input [3:0] rn;
        reg   [3:0] r1;
        begin
            r1        = rn - 4'd1;
            f_pk_last = {3'd0, r1[3:1], 2'b00} + {7'd0, r1[0]} + 8'd5;
        end
    endfunction

    // private index of pass key j (swap: j 0 <-> 1)
    function [4:0] f_pj;
        input [3:0] j;
        input       swap;
        reg   [3:0] jj;
        begin
            jj   = (swap && (j == 4'd0)) ? 4'd1 : (swap && (j == 4'd1)) ? 4'd0 : j;
            f_pj = {jj, 1'b1};
        end
    endfunction

    //==========================================================================
    // common registered datapath controls (one cycle ahead) and store write controls
    //==========================================================================

    reg          gate_r, tsel_r, xws_r;  // next-cycle lookup controls (combinational, registered in round_t)
    reg  [1:0]   asel_r, hs_r;
    reg          ben_ff;
    reg  [4:0]   raddr_ff;
    reg          st_ff;
    reg  [4:0]   waddr_ff;
    reg  [1:0]   wop_ff;

    // EXT commit conversion (combinational, in the commit cycle)
    wire [4:0]   r2_kl    = {kl_rnd, 1'b0};
    wire         kl_dec   = (DIR_DEC != 0) | ((HAS_DEC != 0) & kl_mode);   // per-DIR constant unless BOTH (T6)
    wire [4:0]   ext_idx  = kl_dec ? (r2_kl - kl_waddr) : kl_waddr;
    wire [1:0]   ext_op   = kl_waddr[0] ? OP_TR : (kl_dec ? OP_XW : OP_RAW);
    wire         ext_cmt  = (IS_INT == 0) & kl_st;

    assign st    = ext_cmt | st_ff;
    assign waddr = ext_cmt ? ext_idx : waddr_ff;
    assign wdata = f_op(ext_cmt ? ext_op : wop_ff, ext_cmt ? kl_wdata : tap);

    assign gate_nx = gate_r;
    assign asel_nx = asel_r;
    assign hs_nx   = hs_r;
    assign tsel_nx = tsel_r;
    assign xws_nx  = xws_r;
    assign ben     = ben_ff;
    assign tap_ce  = 1'b1;

    generate
        if (IS_INT != 0) begin : g_int

            //==================================================================
            // INT key schedule
            //==================================================================

            reg          ks_ff, dec_ff;
            wire         dec = (DIR_DEC != 0) | ((DIR_ENC == 0) & dec_ff);   // per-DIR constant unless BOTH (T6)
            reg  [1:0]   kl_ff;
            reg  [3:0]   rn_ff;
            reg  [7:0]   sc_ff;             // setup cycle: s = sc - 2 (sc 0 / 1 = INIT0 / INIT1, s 0 = first F0 lookup)
            reg  [127:0] wk_ff;

            wire [7:0]   s8r     = {1'b0, rn_ff, 3'b000};
            wire [7:0]   pkl     = f_pk_last(rn_ff);
            wire [7:0]   sc_last_c = dec ? (s8r + pkl + 8'd1) : (s8r + 8'd3);

            // registered-state selects (voptimize T5): the setup end / INIT cycles are known one cycle ahead,
            // so own / own_nx / kx_done / the kt_ff selects leave flip-flops (no dec_ff / rn_ff arithmetic in front
            // of the 128-bit kt_ff synchronous reset). sc_last_ff is valid from the cycle after cfg_vld (rn_ff /
            // dec_ff frozen from then on; kx_start comes at least one cycle later).
            reg  [7:0]   sc_last;           // last setup cycle sc
            reg          nl_ff;             // the next cycle is the last setup cycle
            reg          last_ff;           // this is the last setup cycle (kx_done)
            reg          init0_ff, init1_ff;
            always @(posedge clk) begin
                sc_last <= sc_last_c;
                if ((rst_n == RS_ACT) | cfg_vld) begin
                    nl_ff    <= 1'b0;
                    last_ff  <= 1'b0;
                    init0_ff <= 1'b0;
                    init1_ff <= 1'b0;
                end else begin
                    nl_ff    <= ks_ff & ~kx_start & ((sc_ff + 8'd2) == sc_last);
                    last_ff  <= ks_ff & nl_ff;
                    init0_ff <= kx_start;
                    init1_ff <= init0_ff;
                end
            end
            wire         last    = last_ff;
            wire         init0   = init0_ff;
            wire         init1   = init1_ff;

            always @(posedge clk) begin
                if (rst_n == RS_ACT) begin
                    ks_ff  <= 1'b0;
                    dec_ff <= 1'b0;
                    kl_ff  <= 2'd0;
                    rn_ff  <= 4'd6;
                    sc_ff  <= 8'd0;
                end else if (cfg_vld) begin
                    ks_ff  <= 1'b0;
                    dec_ff <= (DIR_DEC != 0) | ((DIR_ENC == 0) & cfg_mode);
                    kl_ff  <= cfg_klen;
                    rn_ff  <= f_rnd(cfg_klen);
                    sc_ff  <= 8'd0;
                end else if (kx_start) begin
                    ks_ff  <= 1'b1;
                    sc_ff  <= 8'd0;
                end else if (ks_ff) begin
                    sc_ff  <= sc_ff + 8'd1;
                    if (last) ks_ff <= 1'b0;
                end
            end

            // K_int: L0 = first 128 bits, R0 = last 128 bits (k=128: ~k0..~k3; 192: k4 k5 ~k2 ~k3; 256: k4..k7)
            wire [127:0] kint_l = cfg_key[255:128];
            wire [127:0] kint_r = (kl_ff == 2'd0) ? ~cfg_key[255:128]
                                : (kl_ff == 2'd1) ? {cfg_key[127:64], ~cfg_key[191:128]}
                                :                   cfg_key[127:0]
                                ;

            // schedule decode, pipelined one cycle ahead so every control leaves a flip-flop:
            //   d_* = decode(s = sc_ff) -> q_* (in cycle s: decode(s+1), the next-cycle lookup controls)
            //   -> c_* (in cycle s: decode(s), the current-cycle selects / store controls)
            // region flags and the pass cycle index of sv are themselves registered one cycle earlier
            wire [7:0]   sv     = sc_ff;
            wire [7:0]   s_lst  = sc_last - 8'd2;
            wire [7:0]   sv_n   = kx_start ? 8'd0 : (sc_ff + 8'd1);
            reg          f0r, pzr, e8r, e81, e0r;
            reg  [7:0]   pkr;
            always @(posedge clk) begin
                f0r <= (sv_n < s8r);
                pzr <= dec & (sv_n >= s8r - 8'd1) & (sv_n <= s_lst);
                e8r <= (sv_n == s8r);
                e81 <= (sv_n == s8r + 8'd1);
                e0r <= (sv_n == 8'd0);
                pkr <= sv_n - s8r + 8'd1;
            end
            wire         d_f0   = f0r;
            wire [2:0]   d_u    = sv[2:0];
            wire [3:0]   d_ii   = sv[6:3] + 4'd1;
            wire         d_pz   = pzr;
            wire [12:0]  d_pass = f_pass(pkr, rn_ff);
            wire         d_plk  = d_pz & d_pass[7] & ~d_f0;
            wire [4:0]   r2     = {rn_ff, 1'b0};
            wire [4:0]   d_i2   = {d_ii, 1'b0};
            wire [4:0]   d_rix  = f_pj(d_pass[11:8], 1'b0);
            wire [4:0]   d_wix  = f_pj(d_pass[3:0], 1'b0);
            wire [127:0] tap_xw = f_xw(tap);

            reg          d_st;
            reg  [4:0]   d_wa;
            reg  [1:0]   d_wo;
            always @* begin
                d_st = 1'b0; d_wa = 5'd0; d_wo = OP_RAW;
                if (d_f0 && (d_u == 3'd5)) begin                            // L_i -> T(L_i)
                    d_st = 1'b1; d_wo = OP_TR;
                    d_wa = dec ? (r2 - d_i2 + 5'd1) : (d_i2 - 5'd1);
                end else if (d_f0 && (d_u == 3'd1) && (sv >= 8'd9)) begin   // R_{i-1}, i >= 2
                    d_st = 1'b1; d_wo = dec ? OP_XW : OP_RAW;
                    d_wa = dec ? (r2 - d_i2 + 5'd2) : (d_i2 - 5'd2);
                end else if (d_pz && d_pass[4]) begin                       // pass write-back
                    d_st = 1'b1; d_wa = d_wix;
                end
            end

            reg          q_gate, q_tsel, q_xws, q_ben, q_st, q_ktkp, q_kpce, q_kpsel, q_wkld;
            reg  [1:0]   q_asel, q_hs, q_wo;
            reg  [4:0]   q_ra, q_wa, q_ctr;
            reg          c_ktkp, c_kpce, c_kpsel, c_wkld;
            reg  [4:0]   c_ctr;
            always @(posedge clk) begin
                if ((rst_n == RS_ACT) | cfg_vld | kx_start | ~ks_ff) begin
                    q_gate <= 1'b0; q_tsel <= 1'b0; q_xws <= 1'b0; q_ben <= 1'b0; q_st <= 1'b0;
                    q_ktkp <= 1'b0; q_kpce <= 1'b0; q_kpsel <= 1'b0; q_wkld <= 1'b0;
                    q_asel <= 2'd0; q_hs <= 2'd0; q_wo <= OP_RAW; q_ra <= 5'd1; q_wa <= 5'd0; q_ctr <= 5'd0;
                end else begin
                    q_gate  <= d_f0 & ~((d_u == 3'd4) | e0r);
                    q_asel  <= d_plk ? (d_pass[6] ? 2'd3 : 2'd2) : 2'd0;
                    q_hs    <= d_plk ? (d_pass[6] ? 2'd2 : 2'd1) : {1'b0, d_u[0]};
                    q_tsel  <= (d_f0 & (d_u == 3'd0) & ~e0r) | e8r;
                    q_xws   <= d_pz & ~d_f0 & ~e8r & d_pass[5];
                    q_ben   <= d_f0 | d_plk;
                    q_ra    <= (d_pz & d_pass[12]) ? d_rix : 5'd1;
                    q_st    <= d_st;
                    q_wa    <= d_wa;
                    q_wo    <= d_wo;
                    q_ktkp  <= d_f0 & ((d_u == 3'd3) | (d_u == 3'd7));
                    q_ctr   <= (d_u == 3'd3) ? (d_i2 - 5'd1) : (d_i2 + 5'd2);
                    q_kpce  <= (d_f0 & (d_u == 3'd5)) | e81;
                    q_kpsel <= dec & e81;
                    q_wkld  <= dec & e81;
                end
            end

            always @(posedge clk) begin
                if ((rst_n == RS_ACT) | cfg_vld | ~ks_ff) begin
                    ben_ff <= 1'b0; raddr_ff <= 5'd1; st_ff <= 1'b0; waddr_ff <= 5'd0; wop_ff <= OP_RAW;
                    c_ktkp <= 1'b0; c_kpce <= 1'b0; c_kpsel <= 1'b0; c_wkld <= 1'b0; c_ctr <= 5'd0;
                end else begin
                    ben_ff <= q_ben; raddr_ff <= q_ra; st_ff <= q_st; waddr_ff <= q_wa; wop_ff <= q_wo;
                    c_ktkp <= q_ktkp; c_kpce <= q_kpce; c_kpsel <= q_kpsel; c_wkld <= q_wkld; c_ctr <= q_ctr;
                end
            end

            // lookup controls of the next cycle
            always @* begin
                gate_r = q_gate;
                asel_r = q_asel;
                hs_r   = q_hs;
                tsel_r = q_tsel;
                xws_r  = q_xws;
            end

            // current-cycle key term / kp / wk (INIT0 / INIT1 decoded directly)
            assign kt_sel_kp   = init1 | c_ktkp;
            assign kt_sel_zero = ~kt_sel_kp;
            assign ctr         = init1 ? 5'd2 : c_ctr;
            assign kp_ce       = init0 | init1 | c_kpce;
            assign kp_sel_in   = init0 | init1 | c_kpsel;
            assign kp_in       = init0 ? kint_r : kint_l;

            always @(posedge clk) begin
                if (init0 & ~dec) begin
                    wk_ff <= kint_l;                                               // K_0^0 = L0
                end else if (c_wkld) begin
                    wk_ff <= tap_xw;                                               // XW(K_post) = XW(R_R)
                end
            end

            wire         run_n  = (ks_ff & ~last & ~nl_ff) | kx_start;                      // next cycle own

            assign own     = ks_ff & ~last;
            assign own_nx  = run_n;
            assign raddr   = raddr_ff;
            assign wk      = wk_ff;
            assign kx_busy = ks_ff;
            assign kx_done = last;
            assign kx_mode = dec;
            assign kx_rnd  = rn_ff;

            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_ext = kl_busy | kl_done | kl_mode | (|kl_rnd) | kl_st | (|kl_waddr) | (|kl_wdata) | (|kl_wk);
            /* verilator lint_on UNUSEDSIGNAL */

        end else begin : g_ext

            //==================================================================
            // EXT: key_ld window, commit conversion (store write path), DEC conversion pass
            //==================================================================

            reg          kd_ff;             // ENC / BOTH-enc: kx_done one cycle after key_ld's
            reg          pa_ff;             // pass running (k >= 0)
            reg          swap_ff;
            reg  [7:0]   pk_ff;             // pass cycle pk = k + 1

            wire         need_pass = kl_dec;
            wire         p_start   = kl_done & need_pass & ~cfg_vld;
            wire [7:0]   pkl       = f_pk_last(kl_rnd);
            wire         p_last    = pa_ff & (pk_ff == pkl);
            wire         swap_d    = (kl_waddr == ({kl_rnd, 1'b0} - 5'd1));   // completing commit = private idx 1

            always @(posedge clk) begin
                if ((rst_n == RS_ACT) | cfg_vld) begin
                    kd_ff   <= 1'b0;
                    pa_ff   <= 1'b0;
                    swap_ff <= 1'b0;
                    pk_ff   <= 8'd0;
                end else begin
                    kd_ff <= kl_done & ~need_pass;
                    if (p_start) begin
                        pa_ff   <= 1'b1;
                        swap_ff <= swap_d;
                        pk_ff   <= 8'd1;
                    end else if (pa_ff) begin
                        pk_ff <= pk_ff + 8'd1;
                        if (p_last) pa_ff <= 1'b0;
                    end
                end
            end

            // next-cycle pass decode. While the load window is open the controls are primed for a pass start
            // in the next cycle (pk 1), so key_ld's combinational kx_done reaches only pa / pk / swap / kd D inputs.
            wire         win    = (HAS_DEC != 0) & kl_busy & ~pa_ff;   // ENC: never a pass, nothing to prime (T1)
            wire [7:0]   pk_n   = win ? 8'd1 : (pk_ff + 8'd1);
            wire         pz_n   = win | (pa_ff & ~p_last);
            wire         swp_n  = win ? swap_d : swap_ff;
            wire [12:0]  pass_n = f_pass(pk_n, kl_rnd);
            wire [4:0]   prd_ix = f_pj(pass_n[11:8], swp_n);
            wire [4:0]   pwr_ix = f_pj(pass_n[3:0], swp_n);
            wire [4:0]   p0_ix  = (kl_st & swap_d) ? 5'd3 : 5'd1;    // read of pass key 0 in the start cycle

            // lookup controls of the next cycle
            always @* begin
                gate_r = 1'b0;
                asel_r = pass_n[6] ? 2'd3 : 2'd2;
                hs_r   = pass_n[6] ? 2'd2 : 2'd1;
                tsel_r = 1'b0;
                xws_r  = pass_n[5];
            end

            always @(posedge clk) begin
                if ((rst_n == RS_ACT) | cfg_vld) begin
                    ben_ff <= 1'b0;
                    raddr_ff <= 5'd1; st_ff <= 1'b0; waddr_ff <= 5'd0; wop_ff <= OP_RAW;
                end else begin
                    ben_ff   <= pz_n & pass_n[7];
                    raddr_ff <= (pz_n & pass_n[12]) ? prd_ix : 5'd1;
                    st_ff    <= pa_ff & ~p_last & pass_n[4];
                    waddr_ff <= pwr_ix;
                    wop_ff   <= OP_RAW;
                end
            end

            // kp: K_post (enc) / K_0^0 (dec) from its commit
            wire kp_idx = kl_dec ? (kl_waddr == 5'd0) : (kl_waddr == r2_kl);

            assign kt_sel_kp   = 1'b0;
            assign kt_sel_zero = 1'b1;
            assign ctr         = 5'd0;
            assign kp_ce       = kl_st & kp_idx;
            assign kp_sel_in   = 1'b1;
            assign kp_in       = kl_wdata;
            assign own         = win | (pa_ff & ~p_last);
            assign own_nx      = win | (pa_ff & ~p_last);
            assign raddr       = win ? p0_ix : raddr_ff;
            assign wk          = kl_wk;
            assign kx_busy     = kl_busy | kd_ff | pa_ff;
            assign kx_done     = need_pass ? p_last : kd_ff;
            assign kx_mode     = kl_dec;
            assign kx_rnd      = kl_rnd;

            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_int = cfg_mode | (|cfg_klen) | (|cfg_key) | kx_start;
            /* verilator lint_on UNUSEDSIGNAL */

        end
    endgenerate

endmodule

`default_nettype wire
