//==============================================================================
// Author       : Pham Cuong
// Created date : 2024/01/25, 14:05
// Modified date: 2024/08/20, 17:05
// Function     : vb_sdp_ram_pp
// Change history is at the end of file
//==============================================================================

// ASIC_MACRO: module name of the RF-compiler wrapper (default stub lib/vb_sdp_ram_macro.v)
`ifndef VB_SDP_RAM_MACRO_NAME
`define VB_SDP_RAM_MACRO_NAME vb_sdp_ram_macro
`endif

module vb_sdp_ram_pp #(
        parameter AWIDTH   = 15,
        parameter DWIDTH   = 16,
        parameter RAM_TYPE = "BLOCK",        // AUTO, ULTRA, BLOCK, DISTRIBUTED, ASIC_FF, ASIC_LATCH, ASIC_MACRO
        parameter PIPELINE = 0,
        parameter INPUTREG = "ON",
        // ASIC extension (2026-11): DEPTH sizes the ASIC_* arrays only (FPGA modes always hold 2**AWIDTH words);
        // ASIC_ICG = 1: ASIC_FF rows written through a per-row clock gate (vb_icg), 0: plain enable flops
        parameter DEPTH    = 2**AWIDTH,
        parameter ASIC_ICG = 1
    ) (
        input clk,
        input st,
        input [AWIDTH-1:0]    waddr,
        input [DWIDTH-1:0]    wdata,
        input ld,
        input [AWIDTH-1:0]    raddr,
        output[DWIDTH-1:0]    rdata
    );

    wire mem_ld;
    wire [AWIDTH-1:0] mem_raddr;
    wire [DWIDTH-1:0] mem_rdata;
    wire mem_st;
    wire [AWIDTH-1:0] mem_waddr;
    wire [DWIDTH-1:0] mem_wdata;

    reg  [DWIDTH-1:0] mem_rdata_ff [0:PIPELINE];

    integer ii;

    initial begin
        for (ii = 0; ii <= PIPELINE; ii = ii + 1) begin
            mem_rdata_ff[ii] = 'd0;
        end
    end

    /* verilator lint_off WIDTH */
    // select input of the mem
    generate
        if (INPUTREG == "ON") begin

            reg mem_ld_ff;
            reg [AWIDTH-1:0] mem_raddr_ff;
            reg mem_st_ff;
            reg [AWIDTH-1:0] mem_waddr_ff;
            reg [DWIDTH-1:0] mem_wdata_ff;

            always @(posedge clk) begin
                mem_ld_ff       <= ld;
                mem_raddr_ff    <= raddr;
                mem_st_ff       <= st;
                mem_waddr_ff    <= waddr;
                mem_wdata_ff    <= wdata;
            end

            assign mem_ld       = mem_ld_ff;
            assign mem_raddr    = mem_raddr_ff;
            assign mem_st       = mem_st_ff;
            assign mem_waddr    = mem_waddr_ff;
            assign mem_wdata    = mem_wdata_ff;

        end else begin

            assign mem_ld       = ld;
            assign mem_raddr    = raddr;
            assign mem_st       = st;
            assign mem_waddr    = waddr;
            assign mem_wdata    = wdata;

        end
    endgenerate

    // assign output
    assign rdata = mem_rdata;

    // instantiate ram model
    generate
        if (RAM_TYPE == "ULTRA") begin
            (* ram_style = "ultra" *)
            reg  [DWIDTH-1:0] mem [0:(2**AWIDTH)-1];
            initial begin
                for (ii = 0; ii < (2**AWIDTH); ii = ii + 1)
                mem[ii] = 'd0;
            end


            always @(posedge clk) begin
                if (mem_ld)
                    mem_rdata_ff[0] <= mem[mem_raddr];

                if (mem_st)
                    mem[mem_waddr] <= mem_wdata;
            end

        end else if (RAM_TYPE == "DISTRIBUTED") begin
            (* ram_style = "distributed" *)
            reg  [DWIDTH-1:0] mem [0:(2**AWIDTH)-1];
            initial begin
                for (ii = 0; ii < (2**AWIDTH); ii = ii + 1)
                mem[ii] = 'd0;
            end


            always @(posedge clk) begin
                if (mem_st)
                    mem[mem_waddr]  <= mem_wdata;

                if (mem_ld)
                    mem_rdata_ff[0] <= mem[mem_raddr];
            end

        end else if (RAM_TYPE == "BLOCK") begin
            (* ram_style = "block" *)
            reg  [DWIDTH-1:0] mem [0:(2**AWIDTH)-1];
            initial begin
                for (ii = 0; ii < (2**AWIDTH); ii = ii + 1)
                mem[ii] = 'd0;
            end


            always @(posedge clk) begin
                if (mem_st)
                    mem[mem_waddr]  <= mem_wdata;

                if (mem_ld)
                    mem_rdata_ff[0] <= mem[mem_raddr];
            end

        end else if ((RAM_TYPE == "ASIC_FF") || (RAM_TYPE == "ASIC_LATCH")) begin : g_asic_rf
            // ASIC register file: DEPTH rows of DWIDTH bits, read mux into mem_rdata_ff[0] (same latency
            // and read-before-write semantics as the FPGA models). Out-of-range read: unspecified (X),
            // out-of-range write: ignored.
            wire [DEPTH*DWIDTH-1:0] rf_rows;
            wire [DWIDTH-1:0]       rf_rd = rf_rows[mem_raddr*DWIDTH +: DWIDTH];

            always @(posedge clk) begin
                if (mem_ld)
                    mem_rdata_ff[0] <= rf_rd;
            end

            if (RAM_TYPE == "ASIC_FF") begin : g_ff
                // flop array; ASIC_ICG = 1: one clock gate per row replaces the DWIDTH enable muxes
                genvar gr;
                for (gr = 0; gr < DEPTH; gr = gr + 1) begin : g_row
                    wire             row_we = mem_st & (mem_waddr == gr);
                    reg [DWIDTH-1:0] row_q;
                    if (ASIC_ICG) begin : g_icg
                        wire gclk;
                        vb_icg icg (.clk(clk), .en(row_we), .se(1'b0), .gclk(gclk));
                        always @(posedge gclk) begin
                            row_q <= mem_wdata;
                        end
                    end else begin : g_en
                        always @(posedge clk) begin
                            if (row_we)
                                row_q <= mem_wdata;
                        end
                    end
                    assign rf_rows[gr*DWIDTH +: DWIDTH] = row_q;
                end
            end else begin : g_latch
                // latch register file: write port staged on posedge, row latch transparent during the
                // following clk-low phase (clock gate on ~clk), read through the mux into mem_rdata_ff[0]
                // at the next posedge. Write -> visible to a read registered one edge later, same as FPGA.
                reg              st_s;
                reg [AWIDTH-1:0] waddr_s;
                reg [DWIDTH-1:0] wdata_s;
                always @(posedge clk) begin
                    st_s    <= mem_st;
                    waddr_s <= mem_waddr;
                    wdata_s <= mem_wdata;
                end
                wire clk_n = ~clk;
                genvar gr;
                for (gr = 0; gr < DEPTH; gr = gr + 1) begin : g_row
                    wire             row_le;
                    reg [DWIDTH-1:0] row_q;
                    vb_icg icg (.clk(clk_n), .en(st_s & (waddr_s == gr)), .se(1'b0), .gclk(row_le));
                    /* verilator lint_off LATCH */
                    always @(*) begin
                        if (row_le)
                            row_q = wdata_s;    // intentional latch row
                    end
                    /* verilator lint_on LATCH */
                    assign rf_rows[gr*DWIDTH +: DWIDTH] = row_q;
                end
            end

        end else if (RAM_TYPE == "ASIC_MACRO") begin : g_asic_macro
            // foundry RF/SRAM compiler macro (black box at synthesis), synchronous read with hold
            wire [DWIDTH-1:0] macro_q;
            `VB_SDP_RAM_MACRO_NAME #(.AWIDTH(AWIDTH), .DWIDTH(DWIDTH), .DEPTH(DEPTH)) imacro (
                .clk(clk), .we(mem_st), .waddr(mem_waddr), .wdata(mem_wdata),
                .re(mem_ld), .raddr(mem_raddr), .rdata(macro_q));
            always @(*) begin
                mem_rdata_ff[0] = macro_q;    // the macro output register is stage 0
            end

        end else begin
            // default mem model auto infer
            reg  [DWIDTH-1:0] mem [0:(2**AWIDTH)-1];
            initial begin
                for (ii = 0; ii < (2**AWIDTH); ii = ii + 1)
                mem[ii] = 'd0;
            end


            always @(posedge clk) begin
                if (mem_ld)
                    mem_rdata_ff[0] <= mem[mem_raddr];

                if (mem_st)
                    mem[mem_waddr] <= mem_wdata;
            end

        end
    endgenerate

    // pipeline ram

    generate
        if (PIPELINE > 0) begin
            
            reg               ld_ff        [0:PIPELINE];

            always @(posedge clk) begin
                ld_ff[0] <= mem_ld;

                for (ii = 1; ii <= PIPELINE; ii = ii + 1) begin
                    ld_ff[ii] <= ld_ff[ii-1];

                    if (ld_ff[ii-1])
                        mem_rdata_ff[ii] <= mem_rdata_ff[ii-1]; 
                end
            end

        end
    endgenerate

    assign mem_rdata = mem_rdata_ff[PIPELINE];

endmodule // vb_sdp_ram_pp

