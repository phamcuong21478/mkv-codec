`default_nettype none

// vb_mkv_sbox_logic : one combinational MKV S-box lane, structural GF(2^4) butterfly (v2, SBOX_IMPL = "LOGIC")
//   GF(16) = GF(2)[z]/(z^4+z+1), polynomial basis; DIR = "ENC" -> fom_s (S only), else fom_both_sh2 (shared S/S^-1)
//   reference: research/sbox/asic/v/fom_s.v, fom_both_sh2.v; golden: spec/model/mkv_ref.py SBOX / INV_SBOX
//   (sva/vb_mkv_sva_tbl.svh mkv_sva_sbox; v4: the vb_mkv_sbox_rom table leaf is retired)
//   v3: ENA_FWD = 0 (DEC + EXT) -> fom_si (S^-1 only, inv ignored), reference research/sbox/asic/v/fom_si.v
module vb_mkv_sbox_logic #(
    parameter DIR     = "BOTH",         //! "ENC" -> S only (inv ignored), "DEC" | "BOTH" -> S and S^-1
    parameter ENA_FWD = 1               //! v3: 0 -> S^-1 only (fom_si, inv ignored; DIR = "DEC" + EXT)
) (
    input  wire [7:0] x,                //! input byte, x[7:4] = high nibble (ALG-ORD-3)
    input  wire       inv,              //! 0 = S, 1 = S^-1 (unused when DIR = "ENC")
    output wire [7:0] y                 //! S(x) or S^-1(x), combinational
);

    //==========================================================================
    // GF(16) helpers (constant functions)
    //==========================================================================

    // GF(16) product, carry-less 7-bit product reduced by z^4 = z+1, z^5 = z^2+z, z^6 = z^3+z^2
    function [3:0] gm;
        input [3:0] a;
        input [3:0] b;
        reg   [6:0] p;
        begin
            p  = ({7{b[0]}} & {3'b000, a})
               ^ ({7{b[1]}} & {2'b00, a, 1'b0})
               ^ ({7{b[2]}} & {1'b0, a, 2'b00})
               ^ ({7{b[3]}} & {a, 3'b000})
               ;
            gm = p[3:0]
               ^ {2'b00, p[4], p[4]}
               ^ {1'b0, p[5], p[5], 1'b0}
               ^ {p[6], p[6], 2'b00}
               ;
        end
    endfunction

    // squaring (linear in GF(2)^4)
    function [3:0] gsq;
        input [3:0] a;
        begin
            gsq = {a[3], a[1] ^ a[3], a[2], a[0] ^ a[2]};
        end
    endfunction

    // inverse a^14, 0 -> 0
    function [3:0] ginv;
        input [3:0] a;
        begin
            case (a)
                4'd0  : ginv = 4'd0;
                4'd1  : ginv = 4'd1;
                4'd2  : ginv = 4'd9;
                4'd3  : ginv = 4'd14;
                4'd4  : ginv = 4'd13;
                4'd5  : ginv = 4'd11;
                4'd6  : ginv = 4'd7;
                4'd7  : ginv = 4'd6;
                4'd8  : ginv = 4'd15;
                4'd9  : ginv = 4'd2;
                4'd10 : ginv = 4'd12;
                4'd11 : ginv = 4'd5;
                4'd12 : ginv = 4'd10;
                4'd13 : ginv = 4'd4;
                4'd14 : ginv = 4'd3;
                4'd15 : ginv = 4'd8;
                default : ginv = 4'd0;
            endcase // a
        end
    endfunction

    function [3:0] g4;                  // a^4
        input [3:0] a;
        begin
            g4 = gsq(gsq(a));
        end
    endfunction

    function [3:0] g8;                  // a^8
        input [3:0] a;
        begin
            g8 = gsq(gsq(gsq(a)));
        end
    endfunction

    //==========================================================================
    // butterfly
    //==========================================================================

    localparam [3:0] ONE = 4'h1;        // GF(16) unit (S affine constant on the low nibble)

    generate
        if (ENA_FWD == 0) begin : g_fom_si
            // fom_si: inverse-only butterfly, t = yr ^ 1, P = yl^-1, Q = t^-1,
            // xr = P^8 * Q ^ [t=0] P, xl = Q^8 * P^2 ^ [yl=0] Q
            wire [3:0] yl = x[7:4];
            wire [3:0] t  = x[3:0] ^ ONE;
            wire [3:0] P  = ginv(yl);
            wire [3:0] Q  = ginv(t);
            wire       zl = ~|yl;
            wire       zt = ~|t;
            wire [3:0] xr = gm(g8(P), Q) ^ ({4{zt}} & P);
            wire [3:0] xl = gm(g8(Q), gsq(P)) ^ ({4{zl}} & Q);
            assign y = {xl, xr};
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_inv = inv;      // S^-1 only
            /* verilator lint_on UNUSEDSIGNAL */
        end else if (DIR == "ENC") begin : g_fom_s
            // fom_s: 2 inversions + 2 multiplications + 2 zero-detect fixups
            wire [3:0] xl = x[7:4];
            wire [3:0] xr = x[3:0];
            wire [3:0] A  = ginv(xl);
            wire [3:0] B  = ginv(xr);
            wire       zl = ~|xl;
            wire       zr = ~|xr;
            wire [3:0] lo = gm(g4(A), xr) ^ ({4{zr}} & A) ^ ONE;
            wire [3:0] hi = gm(g8(xl), g4(B)) ^ ({4{zl}} & B);
            assign y = {hi, lo};
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_inv = inv;      // ENC build: S only
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_fom_both
            // fom_both_sh2: S / S^-1 share both inversions, both multipliers and both fixups;
            // the mode muxes sit on the multiplier operands only (sq(a*b) = sq(a)*sq(b))
            wire [3:0] H  = x[7:4];
            wire [3:0] L  = x[3:0] ^ {3'b000, inv};
            wire [3:0] A  = ginv(H);
            wire [3:0] B  = ginv(L);
            wire       zh = ~|H;
            wire       zl = ~|L;
            wire [3:0] lo = gm(inv ? g8(A) : g4(A), inv ? B : L) ^ ({4{zl}} & A) ^ {3'b000, ~inv};
            wire [3:0] hi = gm(inv ? gsq(A) : g8(H), inv ? g8(B) : g4(B)) ^ ({4{zh}} & B);
            assign y = {hi, lo};
        end
    endgenerate

endmodule

`default_nettype wire
