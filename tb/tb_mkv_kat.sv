// -----------------------------------------------------------------------------
// tb_mkv_kat -- known-answer waveform testbench for vb_mkv_top (Vivado xsim)
//
// For every published KAT that matches the build (BLOCK, PROFILE), the bench:
//   1. loads the key for encryption (INT: MK words + CSR; EXT: CSR + 2R+1 round
//      keys through the staging words and RKIDX), polls CSR, checks ERR and LAT;
//   2. streams NBLK copies of the plaintext back to back and checks every
//      ciphertext, the latency (2R+1) and the block interval (2R), then DCNT;
//   3. loads the same key for decryption and streams the ciphertext back,
//      expecting the plaintext.
// DIR="ENC" builds skip step 3, DIR="DEC" builds skip step 2.
//
// The build parameters come from tb_cfg.vh, written per configuration by the
// Makefile. The ASCII signal tb_phase and the counters tb_vec / tb_blk mark the
// current step in the waveform. The run ends with "[FINISH] PASS" or
// "[FINISH] FAIL".
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

`include "tb_cfg.vh"

module tb_mkv_kat;

    // ---------------- build configuration (from tb_cfg.vh) ----------------
    localparam DIR       = `CFG_DIR;
    localparam TARGET    = `CFG_TARGET;
    localparam SBOX_IMPL = `CFG_SBOX_IMPL;
    localparam PROFILE   = `CFG_PROFILE;
    localparam KEY_SCHED = `CFG_KEY_SCHED;
    localparam RKS_IMPL  = `CFG_RKS_IMPL;
    localparam RS_LV     = `CFG_RS_LV;
    localparam BLOCK     = `CFG_BLOCK;
    localparam DEC_ARCH  = `CFG_DEC_ARCH;

    localparam integer AW      = (BLOCK == 256) ? 5 : 4;
    localparam integer NW      = BLOCK / 32;            // 32-bit words per block / round key
    localparam integer IETF    = (PROFILE == "IETF2026") ? 1 : 0;
    localparam bit     IS_EXT  = (KEY_SCHED == "EXT");
    localparam integer NBLK    = 4;                     // blocks per burst
    localparam integer TCLK    = 10;                    // ns, 100 MHz
    localparam integer POLL_MAX = 4000;                 // CSR / RKIDX poll bound (reads)

    // register word addresses (register_reference.md)
    localparam [AW-1:0] A_CSR = 'h00, A_DCNT = 'h01, A_INFO = 'h02, A_LAT = 'h03, A_RKIDX = 'h0C;
    localparam [31:0]   CSR_CFG_DONE = 32'h2, CSR_ERR = 32'h10, RKIDX_LDRDY = 32'h100;

    `include "mkv_kat_vectors.vh"

    // ---------------- clock / reset ----------------
    reg clk = 1'b0;
    always #(TCLK / 2) clk = ~clk;

    reg  rst_act = 1'b1;                                // 1 = reset asserted
    wire rst_n   = rst_act ? RS_LV[0] : ~RS_LV[0];     // drive the DUT's own reset level

    // ---------------- DUT ----------------
    reg              upi_we = 1'b0, upi_oe = 1'b0;
    reg  [AW-1:0]    upi_addr = '0;
    reg  [31:0]      upi_din = '0;
    wire [31:0]      upi_dout;
    reg              din_valid = 1'b0;
    reg  [BLOCK-1:0] din_data = '0;
    wire             din_ready;
    wire             dout_valid;
    wire [BLOCK-1:0] dout_data;
    reg              dout_ready = 1'b1;

    vb_mkv_top #(
        .DIR       (DIR),
        .TARGET    (TARGET),
        .SBOX_IMPL (SBOX_IMPL),
        .PROFILE   (PROFILE),
        .KEY_SCHED (KEY_SCHED),
        .RKS_IMPL  (RKS_IMPL),
        .RS_LV     (RS_LV),
        .BLOCK     (BLOCK),
        .DEC_ARCH  (DEC_ARCH)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_upi_we   (upi_we),
        .s_upi_oe   (upi_oe),
        .s_upi_addr (upi_addr),
        .s_upi_din  (upi_din),
        .s_upi_dout (upi_dout),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .din_data   (din_data),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready),
        .dout_data  (dout_data)
    );

    // ---------------- waveform markers ----------------
    reg [8*16-1:0] tb_phase = "RESET";                  // show with ASCII radix
    integer        tb_vec   = -1;                       // KAT number in this run
    integer        tb_blk   = -1;                       // block number inside a burst
    reg            tb_mode  = 1'b0;                     // 0 = encrypt, 1 = decrypt
    reg [BLOCK-1:0] tb_expect = '0;                     // expected output of the burst

    // ---------------- cycle counter and stream monitors ----------------
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer         in_stamp  [$];
    integer         out_stamp [$];
    reg [BLOCK-1:0] out_data  [$];
    always @(posedge clk) begin
        if (din_valid && din_ready)   in_stamp.push_back(cyc);
        if (dout_valid && dout_ready) begin
            out_stamp.push_back(cyc);
            out_data.push_back(dout_data);
        end
    end

    // ---------------- check bookkeeping ----------------
    integer n_err = 0, n_chk = 0;
    task automatic check(input bit ok, input string what);
        n_chk++;
        if (!ok) begin
            n_err++;
            $display("[%0t] ERROR: %s", $time, what);
        end
    endtask

    // ---------------- UPI bus tasks ----------------
    // Strobes are driven 1 ns after a rising edge and sampled on the next one.
    task automatic upi_write(input [AW-1:0] a, input [31:0] d);
        @(posedge clk); #1;
        upi_we = 1'b1; upi_addr = a; upi_din = d;
        @(posedge clk); #1;
        upi_we = 1'b0;
    endtask

    task automatic upi_read(input [AW-1:0] a, output [31:0] d);
        @(posedge clk); #1;
        upi_oe = 1'b1; upi_addr = a;
        @(posedge clk); #1;                             // read data valid 1 cycle after the strobe
        upi_oe = 1'b0;
        d = upi_dout;
    endtask

    // MK word i: MK0..MK7 at 0x04..0x0B, MK8..MK15 at 0x10..0x17 (BLOCK=256)
    function automatic [AW-1:0] mk_addr(input integer i);
        mk_addr = (i < 8) ? AW'(4 + i) : AW'(16 + i - 8);
    endfunction

    // poll CSR, OR-accumulating every value (CFG_DONE / ERR are read-to-clear)
    task automatic wait_cfg_done(output [31:0] acc);
        reg [31:0] v;
        integer n;
        acc = 0;
        for (n = 0; n < POLL_MAX; n++) begin
            upi_read(A_CSR, v);
            acc |= v;
            if (acc & (CSR_CFG_DONE | CSR_ERR)) break;
        end
        check(n < POLL_MAX, "timeout waiting for CSR.CFG_DONE");
    endtask

    // ---------------- key setup ----------------
    function automatic integer rounds(input integer klen);
        rounds = 6 + klen + IETF;                       // TCVN2024 6/7/8, IETF2026 7/8/9
    endfunction

    task automatic key_setup(input integer klen, input bit mode);
        reg [511:0] key;
        reg [255:0] rk;
        reg [31:0]  v, acc, lat;
        integer     kw, i, w, n, R;
        R   = rounds(klen);
        key = kat_key(BLOCK, IETF, klen);
        kw  = (BLOCK / 32) * (2 + klen) / 2;            // key words: 4/6/8 (128) or 8/12/16 (256)
        if (!IS_EXT) begin
            tb_phase = mode ? "INT_KEY_DEC" : "INT_KEY_ENC";
            for (i = 0; i < kw; i++)                    // MK0 = key bytes 0..3
                upi_write(mk_addr(i), key[32*(kw-1-i) +: 32]);
            upi_write(A_CSR, (klen << 2) | mode);
        end else begin
            tb_phase = mode ? "EXT_KEY_DEC" : "EXT_KEY_ENC";
            upi_write(A_CSR, (klen << 2) | mode);      // opens the load window
            for (n = 0; n < POLL_MAX; n++) begin
                upi_read(A_RKIDX, v);
                if (v & RKIDX_LDRDY) break;
            end
            check(n < POLL_MAX, "timeout waiting for RKIDX.LDRDY");
            for (i = 0; i <= 2 * R; i++) begin          // K_r^0 -> 2r, K_r^1 -> 2r+1, K_post -> 2R
                rk = kat_rk(BLOCK, IETF, klen, i);
                for (w = 0; w < NW; w++)                // staging MK0 = round-key bytes 0..3
                    upi_write(mk_addr(w), rk[32*(NW-1-w) +: 32]);
                upi_write(A_RKIDX, i);
            end
        end
        tb_phase = "WAIT_CFG_DONE";
        wait_cfg_done(acc);
        check(!(acc & CSR_ERR), $sformatf("CSR.ERR set after key setup (CSR acc = 0x%08h)", acc));
        upi_read(A_LAT, lat);
        check(lat == {8'd0, 8'(2*R+1), 8'(2*R), 4'd0, 4'(R)},
              $sformatf("LAT = 0x%08h, expected R = %0d", lat, R));
    endtask

    // ---------------- streaming ----------------
    task automatic stream_burst(input [BLOCK-1:0] blk_in, input [BLOCK-1:0] blk_exp, input integer klen,
                                input bit mode);
        integer R, i, n;
        reg [31:0] dcnt;
        R = rounds(klen);
        tb_phase  = mode ? "DECRYPT" : "ENCRYPT";
        tb_expect = blk_exp;
        in_stamp.delete(); out_stamp.delete(); out_data.delete();
        for (i = 0; i < NBLK; i++) begin                // back-to-back valid/ready source
            tb_blk = i;
            @(posedge clk); #1;
            din_valid = 1'b1; din_data = blk_in;
            do @(posedge clk); while (!din_ready);
            #1 din_valid = 1'b0;
        end
        tb_phase = "DRAIN";
        for (n = 0; n < 64 * R && out_data.size() < NBLK; n++) @(posedge clk);
        check(out_data.size() == NBLK, $sformatf("%0d of %0d output blocks received", out_data.size(), NBLK));
        for (i = 0; i < out_data.size(); i++)
            check(out_data[i] == blk_exp, $sformatf("block %0d: got %h, expected %h", i, out_data[i], blk_exp));
        if (out_data.size() == NBLK) begin
            // latency counted as in integration_guide.md §6.2: transfer in cycle t -> dout_valid in t + 2R + 1
            check(out_stamp[0] - in_stamp[0] == 2 * R + 1,
                  $sformatf("latency %0d cycles, expected 2R+1 = %0d", out_stamp[0] - in_stamp[0], 2 * R + 1));
            for (i = 1; i < NBLK; i++)
                check(in_stamp[i] - in_stamp[i-1] == 2 * R,
                      $sformatf("interval %0d cycles, expected 2R = %0d", in_stamp[i] - in_stamp[i-1], 2 * R));
            $display("[%0t]   %s %0d blocks: latency %0d, interval %0d cycles", $time,
                     mode ? "decrypt" : "encrypt", NBLK, out_stamp[0] - in_stamp[0], in_stamp[1] - in_stamp[0]);
        end
        tb_blk = -1;
        upi_read(A_DCNT, dcnt);                         // read-to-clear
        check(dcnt == NBLK, $sformatf("DCNT = %0d, expected %0d", dcnt, NBLK));
    endtask

    // ---------------- main sequence ----------------
    function automatic [31:0] info_expected();
        info_expected = 32'h04;
        info_expected[9:8] = (DIR == "ENC") ? 2'd0 : (DIR == "DEC") ? 2'd1 : 2'd2;
        info_expected[10]  = (SBOX_IMPL == "BRAM");
        info_expected[11]  = IETF[0];
        info_expected[12]  = (TARGET == "ASIC");
        info_expected[13]  = IS_EXT;
        info_expected[14]  = (BLOCK == 256);
    endfunction

    initial begin : main
        reg [31:0] v;
        reg [BLOCK-1:0] pt, ct;
        integer klen, nvec;
        bit do_enc, do_dec;
        do_enc = (DIR != "DEC");
        do_dec = (DIR != "ENC");
        nvec   = 0;
        $timeformat(-9, 0, " ns", 10);

        $display("==============================================================");
        $display(" tb_mkv_kat: BLOCK=%0d DIR=%s TARGET=%s SBOX_IMPL=%s PROFILE=%s", BLOCK, DIR, TARGET,
                 SBOX_IMPL, PROFILE);
        $display("             KEY_SCHED=%s RKS_IMPL=%s RS_LV=%0d DEC_ARCH=%s", KEY_SCHED, RKS_IMPL, RS_LV,
                 DEC_ARCH);
        $display("==============================================================");

        repeat (5) @(posedge clk);
        #1 rst_act = 1'b0;
        repeat (2) @(posedge clk);

        tb_phase = "READ_INFO";
        upi_read(A_INFO, v);
        check(v == info_expected(), $sformatf("INFO = 0x%08h, expected 0x%08h", v, info_expected()));
        upi_read(A_CSR, v);
        check(v == ((DIR == "DEC") ? 32'h1 : 32'h0), $sformatf("CSR after reset = 0x%08h", v));
        $display("[%0t] INFO = 0x%08h", $time, info_expected());

        for (klen = 0; klen < 3; klen++) begin
            if (!kat_avail(BLOCK, IETF, klen)) begin
                $display("[%0t] KLEN=%0d: no published vector for %s MKV-%0d, skipped", $time, klen, PROFILE, BLOCK);
                continue;
            end
            tb_vec = nvec++;
            pt = kat_pt(BLOCK, IETF, klen);
            ct = kat_ct(BLOCK, IETF, klen);
            $display("[%0t] KAT %0d: %s MKV-%0d, KLEN=%0d (%0d-bit key, R=%0d)", $time, tb_vec, PROFILE, BLOCK,
                     klen, BLOCK * (2 + klen) / 2, rounds(klen));
            $display("            PT = %h", pt);
            $display("            CT = %h", ct);
            if (do_enc) begin
                tb_mode = 1'b0;
                key_setup(klen, 1'b0);
                stream_burst(pt, ct, klen, 1'b0);
            end
            if (do_dec) begin
                tb_mode = 1'b1;
                key_setup(klen, 1'b1);
                stream_burst(ct, pt, klen, 1'b1);
            end
        end

        tb_phase = "DONE";
        repeat (10) @(posedge clk);
        $display("--------------------------------------------------------------");
        $display(" %0d KAT(s), %0d checks, %0d error(s)", nvec, n_chk, n_err);
        if (n_err == 0 && nvec > 0) $display("[FINISH] PASS");
        else                        $display("[FINISH] FAIL");
        $finish;
    end

    // global watchdog
    initial begin
        #(TCLK * 200000);
        $display("[%0t] ERROR: watchdog timeout", $time);
        $display("[FINISH] FAIL");
        $finish;
    end

endmodule

`default_nettype wire
