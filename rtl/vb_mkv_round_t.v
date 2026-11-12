`default_nettype none

// vb_mkv_round_t : engine-T datapath (vb_mkv_eng_t, arch v4 section 14.2): 16 T-box lanes in 8 vb_mkv_tbox_rom,
//   transposed lane network, key-term / output-key / tap / output registers.
//   Lane (x,y), bus byte n = 4x+y (bus[127-8n -: 8]), reads table column v = y:
//     T lookup (half T / T^-1) : lane (x,y) holds state byte (word x, pos y)
//     S lookup (half XW / XW^-1): lane (x,y) holds m byte (word y, pos x)
//   Every lane address bit: addr = (gate & XOR4) ^ kt_eff, XOR4 = XOR of the 4 lane outputs (y,0..3) field [8x+b]
//   -> one LUT6 from the BRAM output latches to the BRAM address (kt_eff and gate are FF-sourced).
//   kt_eff (asel): 0 kt_ff, 1 load value ldv ^ wk (ldv = din, DEC XW(din)), 2 store read data rk, 3 tap_ff
//   (2 / 3 = DEC conversion pass only; DIR = "ENC": 2-way kt_ff / load).
module vb_mkv_round_t #(
    parameter DIR   = "BOTH",           //! "ENC": table halves {T, XW}; "DEC" / "BOTH": {T, XW, T^-1, XW^-1}
    parameter RS_LV = 0                 //! reset active level (0 = active-low)
) (
    input  wire         clk,            //! clock
    input  wire         rst_n,          //! synchronous reset, asserted when rst_n == RS_LV (control registers)

    // lookup controls of the NEXT cycle (registered here)
    input  wire         gate_nx,        //! 1: address = XOR4 ^ kt_eff, 0: address = kt_eff
    input  wire [1:0]   asel_nx,        //! kt_eff source: 0 kt_ff, 1 ldv ^ wk, 2 rk, 3 tap_ff
    input  wire [1:0]   hs_nx,          //! table half: 0 T, 1 XW, 2 T^-1, 3 XW^-1
    input  wire         tsel_nx,        //! tap key: 1 -> tap = X ^ kp_ff, 0 -> tap = X
    input  wire         xws_nx,         //! tap XW: 1 -> X = XW(XOR4), 0 -> X = XOR4
    input  wire         ben,            //! BRAM read enable (this cycle; 0 holds the lane outputs)

    // key terms and data
    input  wire         ld_dec,         //! load value is XW(din) (decryption) instead of din
    input  wire [127:0] din,            //! input block (load cycle)
    input  wire [127:0] wk,             //! whitening key: K_0^0 (enc) / XW(K_post) (dec)
    input  wire [127:0] rk,             //! round-key store read data (registered in the store)
    input  wire         kt_sel_kp,      //! kt_ff <= kp_ff ^ {123'd0, ctr} (key schedule chain start)
    input  wire         kt_sel_zero,    //! kt_ff <= 0 (key schedule F0); else kt_ff <= rk
    input  wire [4:0]   ctr,            //! key schedule counter <i> (last byte only)
    input  wire         kp_ce,          //! kp_ff load enable
    input  wire         kp_sel_in,      //! kp_ff <= kp_in (1) / tap_ff (0)
    input  wire [127:0] kp_in,          //! external kp_ff value (K_int halves, EXT commit data)
    input  wire         tap_ce,         //! tap_ff load enable
    input  wire         dout_ce,        //! dout_ff load enable (output capture)
    input  wire         dout_dec,       //! output = XW(XOR4) ^ kp_ff (decryption) instead of XOR4 ^ kp_ff

    output wire [127:0] tap,            //! tap_ff (key schedule / conversion values)
    output wire [127:0] dout_data       //! dout_ff (output block)
);

    /* verilator lint_off WIDTHEXPAND */
    localparam HAS_DEC = (DIR != "ENC") ? 1 : 0;
    /* verilator lint_on WIDTHEXPAND */
    localparam HALVES  = (HAS_DEC != 0) ? 4 : 2;
    localparam RS_ACT  = (RS_LV != 0) ? 1'b1 : 1'b0;

    // XWords: each 32-bit sub-state xored with the xor of all four sub-states
    function [127:0] f_xw;
        input [127:0] x;
        reg   [31:0]  s;
        begin
            s    = x[127:96] ^ x[95:64] ^ x[63:32] ^ x[31:0];
            f_xw = x ^ {s, s, s, s};
        end
    endfunction

    //==========================================================================
    // registered lookup controls (fan-out 128: replicated by max_fanout)
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

    reg  [127:0] kt_ff;
    reg  [127:0] kp_ff;
    reg  [127:0] tap_ff;
    reg  [127:0] dout_ff;

    wire [127:0] ldv    = ((HAS_DEC != 0) && ld_dec) ? f_xw(din) : din;
    // kt_eff sources 2 / 3 serve only the DEC M4^-1 conversion pass: DIR = "ENC" has no pass, so its key term is
    // the 2-way load / kt_ff select (voptimize T1; the load term stays combinational for latency 2R+1). The ENC
    // select is kept as its own FF-side net: folded into the address cone (8 inputs) it would make the
    // BRAM -> BRAM path 2 LUT levels.
    wire [127:0] kt_eff;
    generate
        if (HAS_DEC == 0) begin : g_kte_enc
            (* keep = "true" *) wire [127:0] kt_eff_e = asel_ff[0] ? (ldv ^ wk) : kt_ff;
            assign kt_eff = kt_eff_e;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_asel = asel_ff[1];      // never set in ENC builds (SVA seq_asel_enc)
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_kte_dec
            assign kt_eff = (asel_ff == 2'd1) ? (ldv ^ wk)
                          : (asel_ff == 2'd2) ? rk
                          : (asel_ff == 2'd3) ? tap_ff
                          :                     kt_ff
                          ;
        end
    endgenerate
    wire [127:0] kt_d   = kt_sel_kp   ? (kp_ff ^ {123'd0, ctr})
                        : kt_sel_zero ? 128'd0
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
    // T-box lanes: 8 ROMs, ROM (y, p) = lanes (2p, y) [port A] and (2p+1, y) [port B], column v = y
    //==========================================================================

    wire [127:0] addr;                  // lane addresses, byte n = 4x+y
    wire [127:0] x4v;                   // XOR4 network values
    wire [31:0]  dol [0:15];            // lane outputs, index 4x+y

    genvar y, p, x, b;
    generate
        for (y = 0; y < 4; y = y + 1) begin : g_y
            for (p = 0; p < 2; p = p + 1) begin : g_p
                vb_mkv_tbox_rom #(
                    .V      (y),
                    .HALVES (HALVES)
                ) irom (
                    .clk    (clk),
                    .en     (ben),
                    .addr_a ({hs_ff, addr[127 - 8 * (4 * (2 * p) + y) -: 8]}),
                    .addr_b ({hs_ff, addr[127 - 8 * (4 * (2 * p + 1) + y) -: 8]}),
                    .do_a   (dol[4 * (2 * p) + y]),
                    .do_b   (dol[4 * (2 * p + 1) + y])
                );
            end
        end

        // network: lane (x,y) bit b = XOR_v of lane (y,v) output field [8x+b]
        for (x = 0; x < 4; x = x + 1) begin : g_x
            for (y = 0; y < 4; y = y + 1) begin : g_ly
                for (b = 0; b < 8; b = b + 1) begin : g_b
                    localparam integer BI = 127 - 8 * (4 * x + y) - 7 + b;
                    wire x4 = dol[4 * y + 0][8 * x + b] ^ dol[4 * y + 1][8 * x + b]
                            ^ dol[4 * y + 2][8 * x + b] ^ dol[4 * y + 3][8 * x + b];
                    assign x4v[BI]  = x4;
                    assign addr[BI] = (gate_ff & x4) ^ kt_eff[BI];
                end
            end
        end
    endgenerate

    // tap: X ^ (tsel ? kp : 0), X = XW(XOR4) when xws; output: XOR4 ^ kp (enc) / XW(XOR4) ^ kp (dec)
    wire [127:0] x4w    = f_xw(x4v);
    wire [127:0] tap_d  = (xws_ff ? x4w : x4v) ^ (tsel_ff ? kp_ff : 128'd0);
    wire [127:0] dout_d = (((HAS_DEC != 0) && dout_dec) ? x4w : x4v) ^ kp_ff;

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
