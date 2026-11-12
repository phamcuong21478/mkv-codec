`default_nettype none

// vb_mkv_round_t256 : engine-T256 datapath (vb_mkv_eng_t256, arch v5.1 section 15.15.3): 32 T-box lanes in
//   16 vb_mkv_tbox256_rom, the fixed XOR8 lane network, key-term / output-key / tap / output registers.
//   Physical lane (i, j), i = row 0..7, j = column 0..3, bus byte n = 8j + i (bus[255-8n -: 8]); lane (i, j) reads
//   row table ROW = i; ROM instance (i, p): port A = lane (i, 2p), port B = lane (i, 2p+1).
//   XOR8 network (both halves): target lane (i, j) bit b = XOR over the 8 lanes (r, i/2), r = 0..7, of output slice
//   s = 2j + i%2 (lane word bits [63-8s -: 8]):
//     T half (M8 x S, column output) leaves the state in layout L_B (physical byte 8j+i <- logical byte
//     8(i/2) + 2j + i%2); the XW half (row output, 3 non-zero slices) returns it to the identity layout.
//   Every lane address bit: addr = (gate & XOR8) ^ kt_eff -> exactly 2 LUT levels from the BRAM output latches
//   (XOR6 partial kept as its own LUT6, then gate & (p6 ^ d6 ^ d7) ^ kt_eff); kt_eff and gate are FF-sourced.
//   kt_eff (asel): 0 kt_ff, 1 load value ldv ^ wk (ldv = din, DEC XW(din)), 2 store read data rk, 3 tap_ff
//   (2 / 3 = DEC conversion pass only; DIR = "ENC": 2-way kt_ff / load).
module vb_mkv_round_t256 #(
    parameter DIR   = "BOTH",           //! "ENC": table halves {T, XW}; "DEC" / "BOTH": {T, XW, T^-1, XW^-1}
    parameter RS_LV = 0                 //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV (control registers)

    // lookup controls of the NEXT cycle (registered here)
    input  wire         gate_nx,        //! 1: address = XOR8 ^ kt_eff, 0: address = kt_eff
    input  wire [1:0]   asel_nx,        //! kt_eff source: 0 kt_ff, 1 ldv ^ wk, 2 rk, 3 tap_ff
    input  wire [1:0]   hs_nx,          //! table half: 0 T, 1 XW, 2 T^-1, 3 XW^-1
    input  wire         tsel_nx,        //! tap key: 1 -> tap = X ^ kp_ff, 0 -> tap = X
    input  wire         xws_nx,         //! tap XW: 1 -> X = XW(XOR8), 0 -> X = XOR8
    input  wire         ben,            //! BRAM read enable (this cycle; 0 holds the lane outputs)

    // key terms and data
    input  wire         ld_dec,         //! load value is XW(din) (decryption) instead of din
    input  wire [255:0] din,            //! input block (load cycle)
    input  wire [255:0] wk,             //! whitening key: K_0^0 (enc) / XW(K_post) (dec)
    input  wire [255:0] rk,             //! round-key store read data (registered in the store)
    input  wire         kt_sel_kp,      //! kt_ff <= kp_ff ^ {251'd0, ctr} (key schedule chain start)
    input  wire         kt_sel_zero,    //! kt_ff <= 0 (key schedule F0); else kt_ff <= rk
    input  wire [4:0]   ctr,            //! key schedule counter <i> (last byte only)
    input  wire         kp_ce,          //! kp_ff load enable
    input  wire         kp_sel_in,      //! kp_ff <= kp_in (1) / tap_ff (0)
    input  wire [255:0] kp_in,          //! external kp_ff value (K_int halves, EXT commit data)
    input  wire         tap_ce,         //! tap_ff load enable
    input  wire         dout_ce,        //! dout_ff load enable (output capture)
    input  wire         dout_dec,       //! output = XW(XOR8) ^ kp_ff (decryption) instead of XOR8 ^ kp_ff

    output wire [255:0] tap,            //! tap_ff (key schedule / conversion values)
    output wire [255:0] dout_data       //! dout_ff (output block)
);

    /* verilator lint_off WIDTHEXPAND */
    localparam HAS_DEC = (DIR != "ENC") ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */
    localparam HALVES  = (HAS_DEC != 0) ? 4 : 2;
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;

    // XWords: each 64-bit sub-state xored with the xor of all four sub-states
    function [255:0] f_xw;
        input [255:0] x;
        reg   [63:0]  s;
        begin
            s    = x[255:192] ^ x[191:128] ^ x[127:64] ^ x[63:0];
            f_xw = x ^ {s, s, s, s};
        end
    endfunction

    //==========================================================================
    // registered lookup controls (fan-out 256: replicated by max_fanout)
    //==========================================================================

    (* max_fanout = 32 *) reg         gate_ff;
    (* max_fanout = 32 *) reg [1:0]   asel_ff;
    (* max_fanout = 16 *) reg [1:0]   hs_ff;
    (* max_fanout = 32 *) reg         tsel_ff;
    (* max_fanout = 32 *) reg         xws_ff;
    always @(posedge clk) begin
        if (rst_n == RS_ACT) begin
            gate_ff <= 1'b0;
            asel_ff <= 2'd0;
            hs_ff   <= 2'd0;
            tsel_ff <= 1'b0;
            xws_ff  <= 1'b0;
        end else begin
            gate_ff <= gate_nx;
            asel_ff <= asel_nx;
            hs_ff   <= hs_nx;
            tsel_ff <= tsel_nx;
            xws_ff  <= (HAS_DEC != 0) & xws_nx;
        end
    end

    //==========================================================================
    // key-term, output-key, tap and output registers (datapath, no reset, LSN-8)
    //==========================================================================

    reg  [255:0] kt_ff;
    reg  [255:0] kp_ff;
    reg  [255:0] tap_ff;
    reg  [255:0] dout_ff;

    wire [255:0] ldv    = ((HAS_DEC != 0) && ld_dec) ? f_xw(din) : din;
    // kt_eff is kept as its own FF-side net (keep): folded into the address cone the BRAM -> BRAM path would grow
    // beyond 2 LUT levels. Sources 2 / 3 serve only the DEC M8^-1 conversion pass (ENC: 2-way select, T1).
    wire [255:0] kt_eff;
    generate
        if (HAS_DEC == 0) begin : g_kte_enc
            (* keep = "true" *) wire [255:0] kt_eff_e = asel_ff[0] ? (ldv ^ wk) : kt_ff;
            assign kt_eff = kt_eff_e;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_asel = asel_ff[1];      // never set in ENC builds (SVA seq_asel_enc)
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_kte_dec
            (* keep = "true" *) wire [255:0] kt_eff_d = (asel_ff == 2'd1) ? (ldv ^ wk)
                                                     : (asel_ff == 2'd2) ? rk
                                                     : (asel_ff == 2'd3) ? tap_ff
                                                     :                     kt_ff
                                                     ;
            assign kt_eff = kt_eff_d;
        end
    endgenerate
    wire [255:0] kt_d   = kt_sel_kp   ? (kp_ff ^ {251'd0, ctr})
                        : kt_sel_zero ? 256'd0
                        :               rk
                        ;

    always @(posedge clk) begin
        kt_ff <= kt_d;
    end

    always @(posedge clk) begin
        if (kp_ce) begin
            kp_ff <= kp_sel_in ? kp_in : tap_ff;
        end
    end

    //==========================================================================
    // T-box lanes: 16 ROMs, ROM (i, p) = lanes (i, 2p) [port A] and (i, 2p+1) [port B], row table i
    //==========================================================================

    wire [255:0] addr;                  // lane addresses, byte n = 8j + i
    wire [255:0] x8v;                   // XOR8 network values
    wire [63:0]  dol [0:31];            // lane outputs, index 8j + i

    genvar i, p, j, b;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_i
            for (p = 0; p < 2; p = p + 1) begin : g_p
                vb_mkv_tbox256_rom #(
                    .ROW    (i),
                    .HALVES (HALVES)
                ) irom (
                    .clk    (clk),
                    .en     (ben),
                    .addr_a ({hs_ff, addr[255 - 8 * (8 * (2 * p) + i) -: 8]}),
                    .addr_b ({hs_ff, addr[255 - 8 * (8 * (2 * p + 1) + i) -: 8]}),
                    .do_a   (dol[8 * (2 * p) + i]),
                    .do_b   (dol[8 * (2 * p + 1) + i])
                );
            end
        end

        // network: lane (i, j) bit b = XOR_r of lane (r, i/2) output slice s = 2j + i%2, bit b
        for (j = 0; j < 4; j = j + 1) begin : g_j
            for (i = 0; i < 8; i = i + 1) begin : g_li
                for (b = 0; b < 8; b = b + 1) begin : g_b
                    localparam integer BI = 255 - 8 * (8 * j + i) - 7 + b;     // bus bit of lane (i, j), bit b
                    localparam integer C  = i / 2;                              // source column
                    localparam integer SB = 63 - 8 * (2 * j + i % 2) - 7 + b;  // source slice bit
                    // 2 LUT levels: XOR6 partial (kept as its own LUT6), then (gate & (p6 ^ d6 ^ d7)) ^ kt
                    (* keep = "true" *) wire p6 = dol[8 * C + 0][SB] ^ dol[8 * C + 1][SB] ^ dol[8 * C + 2][SB]
                                                ^ dol[8 * C + 3][SB] ^ dol[8 * C + 4][SB] ^ dol[8 * C + 5][SB];
                    wire x8 = p6 ^ dol[8 * C + 6][SB] ^ dol[8 * C + 7][SB];
                    assign x8v[BI]  = x8;
                    assign addr[BI] = (gate_ff & x8) ^ kt_eff[BI];
                end
            end
        end
    endgenerate

    // tap: X ^ (tsel ? kp : 0), X = XW(XOR8) when xws; output: XOR8 ^ kp (enc) / XW(XOR8) ^ kp (dec)
    wire [255:0] x8w    = f_xw(x8v);
    wire [255:0] tap_d  = (xws_ff ? x8w : x8v) ^ (tsel_ff ? kp_ff : 256'd0);
    wire [255:0] dout_d = (((HAS_DEC != 0) && dout_dec) ? x8w : x8v) ^ kp_ff;

    always @(posedge clk) begin
        if (tap_ce) begin
            tap_ff <= tap_d;
        end
    end

    always @(posedge clk) begin
        if (dout_ce) begin
            dout_ff <= dout_d;
        end
    end

    assign tap       = tap_ff;
    assign dout_data = dout_ff;

endmodule

`default_nettype wire
