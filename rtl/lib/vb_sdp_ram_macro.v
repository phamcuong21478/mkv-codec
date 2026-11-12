//==============================================================================
// Function     : vb_sdp_ram_macro - stand-in for a foundry register-file / SRAM compiler macro
//   (1 write port, 1 read port, one clock, synchronous read with output hold on re = 0,
//   read-before-write on a same-address collision). Used by vb_sdp_ram_pp RAM_TYPE = "ASIC_MACRO".
//   Simulation: behavioural model below. Synthesis / integration: define VB_SDP_RAM_MACRO_BLACKBOX to
//   get an empty (* blackbox *) shell, or replace this file by a wrapper around the compiled macro
//   with the same module name and ports (or set VB_SDP_RAM_MACRO_NAME, see vb_sdp_ram_pp.v).
//==============================================================================
`default_nettype none

`ifdef VB_SDP_RAM_MACRO_BLACKBOX
(* blackbox *)
`endif
module vb_sdp_ram_macro #(
    parameter AWIDTH = 5,               //! address width
    parameter DWIDTH = 128,             //! data width
    parameter DEPTH  = 2**AWIDTH        //! words (may be < 2**AWIDTH)
) (
    input  wire              clk,       //! clock
    input  wire              we,        //! write enable
    input  wire [AWIDTH-1:0] waddr,     //! write address (>= DEPTH: write ignored)
    input  wire [DWIDTH-1:0] wdata,     //! write data
    input  wire              re,        //! read enable (0 holds rdata)
    input  wire [AWIDTH-1:0] raddr,     //! read address (>= DEPTH: rdata unspecified)
    output reg  [DWIDTH-1:0] rdata      //! registered read data
);

`ifndef VB_SDP_RAM_MACRO_BLACKBOX
    localparam [AWIDTH:0] DEPTH_W = DEPTH[AWIDTH:0];  // depth as an AWIDTH+1-bit constant
    reg [DWIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we && ({1'b0, waddr} < DEPTH_W))
            mem[waddr] <= wdata;
        if (re)
            rdata <= mem[raddr];
    end
`endif

endmodule // vb_sdp_ram_macro

`default_nettype wire
