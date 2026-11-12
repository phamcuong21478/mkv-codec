`default_nettype none

// vb_mkv_lin_m8i : one 64-bit column of MKV-256 invMixWords M8^-1 over GF(2^8)/0x12B, realised as
//   M8^-1 = J*M8*J (J = byte reversal inside the column; arch v5 sections 15.1 / 15.15.2, A-26,
//   ddoc/vb_mkv_lin_m8i_req.md): byte-reversed input -> one vb_mkv_lin_m8 instance -> byte-reversed output.
//   Pure wiring around the generated M8 leaf (no second SLP program, no generator). Used 4x by
//   vb_mkv_round_a256s (V1, DEC_ARCH = "SEP") only. Proof (basis + random vs mkv_ref.M8_INV):
//   research/gf/emit_lin_m8_rtl.py and tb/vb_mkv_lin_m8/.
module vb_mkv_lin_m8i (
    input  wire [63:0] x,               //! column input, element 0 = x[63:56]
    output wire [63:0] y                //! M8^-1 * x over GF(2^8)/0x12B, element 0 = y[63:56]
);

    wire [63:0] xj;                     // J(x): byte j -> byte 7 - j
    wire [63:0] yj;                     // M8 * J(x)

    assign xj = {x[7:0], x[15:8], x[23:16], x[31:24], x[39:32], x[47:40], x[55:48], x[63:56]};

    vb_mkv_lin_m8 im8 (
        .x (xj),
        .y (yj)
    );

    assign y  = {yj[7:0], yj[15:8], yj[23:16], yj[31:24], yj[39:32], yj[47:40], yj[55:48], yj[63:56]};

endmodule

`default_nettype wire
