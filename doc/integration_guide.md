# vb_mkv Integration Guide — v1.1.0

This guide is for an engineer integrating `vb_mkv` into an ASIC or FPGA design. It is self-contained: together with
`register_reference.md` and `programming_guide.md` it gives everything needed to instantiate and drive the IP.

## 1. Files to compile

Add every file under `rtl/` and `rtl/lib/`. The top module is **`vb_mkv_top`** (`rtl/vb_mkv_top.v`). All RTL is
Verilog-2005 (IEEE 1364-2005), and synthesis needs no SystemVerilog. The hierarchy is self-contained:

| File(s) | Used by |
|---|---|
| `rtl/vb_mkv_top.v`, `vb_mkv_reg.v`, `vb_mkv_core.v`, `vb_mkv_cfg.v` | every build |
| `rtl/vb_mkv_key_ld.v` | BLOCK=128 EXT (engines A and T) |
| `rtl/vb_mkv_eng_a.v`, `vb_mkv_seq_a.v`, `vb_mkv_kx_a.v`, `vb_mkv_round_a.v`, `vb_mkv_lin_slp.v` | engine A (BLOCK=128: ASIC, FPGA LOGIC) |
| `rtl/vb_mkv_eng_t.v`, `vb_mkv_seq_t.v`, `vb_mkv_kx_t.v`, `vb_mkv_round_t.v`, `vb_mkv_tbox_rom.v` | engine T (BLOCK=128: FPGA BRAM) |
| `rtl/vb_mkv_sbox_logic.v` | engines A and A256 |
| `rtl/vb_mkv_eng_a256.v`, `vb_mkv_seq_a256.v`, `vb_mkv_kx_a256.v`, `vb_mkv_round_a256.v`, `vb_mkv_round_a256s.v`, `vb_mkv_lin_m8.v`, `vb_mkv_lin_m8i.v` | engine A256 (BLOCK=256: ASIC, FPGA LOGIC) |
| `rtl/vb_mkv_eng_t256.v`, `vb_mkv_kx_t256.v`, `vb_mkv_round_t256.v`, `vb_mkv_tbox256_rom.v` (+ `vb_mkv_seq_t.v`) | engine T256 (BLOCK=256: FPGA BRAM) |
| `rtl/vb_mkv_key_ld256.v` | BLOCK=256 EXT (engines A256 and T256) |
| `rtl/lib/vb_sdp_ram_pp.v` | round-key store, every build |
| `rtl/lib/vb_icg.v` | ASIC `RKS_IMPL="FF"` / `"LATCH"` (row clock gates) |
| `rtl/lib/vb_sdp_ram_macro.v` | ASIC `RKS_IMPL="MACRO"` (behavioural stand-in for your RF macro) |

Only one engine is elaborated per build (generate). Compiling the unused engines' files is harmless.

## 2. Instantiation

```verilog
vb_mkv_top #(
    .DIR       ("BOTH"),       // "ENC" | "DEC" | "BOTH"
    .TARGET    ("ASIC"),       // "ASIC" (product) | "FPGA" (PoC)
    .SBOX_IMPL ("LOGIC"),      // "LOGIC" | "BRAM" (FPGA only) | "LUT" (alias of LOGIC)
    .PROFILE   ("TCVN2024"),   // "TCVN2024" | "IETF2026"
    .KEY_SCHED ("INT"),        // "INT" | "EXT"
    .RKS_IMPL  ("LATCH"),      // "FF" | "LATCH" | "MACRO" (ASIC only; ignored on FPGA)
    .RS_LV     (0),            // 0 = active-low reset
    .BLOCK     (256),          // 128 (MKV-128, default) | 256 (MKV-256)
    .DEC_ARCH  ("JDOM")        // "JDOM" (default, recommended) | "SEP"; only A256 with DIR != "ENC"
) u_mkv (
    .clk        (clk),
    .rst_n      (rst_n),
    .s_upi_we   (upi_we),
    .s_upi_oe   (upi_oe),
    .s_upi_addr (upi_addr),    // [4:0] word address at BLOCK=256, [3:0] at BLOCK=128
    .s_upi_din  (upi_wdata),   // [31:0]
    .s_upi_dout (upi_rdata),   // [31:0] valid 1 cycle after upi_oe
    .din_valid  (in_valid),
    .din_ready  (in_ready),
    .din_data   (in_block),    // [BLOCK-1:0] B[0] in the most significant byte
    .dout_valid (out_valid),
    .dout_ready (out_ready),
    .dout_data  (out_block)    // [BLOCK-1:0] B[0] in the most significant byte
);
```

Parameter order: `DIR, TARGET, SBOX_IMPL, PROFILE, KEY_SCHED, RKS_IMPL, RS_LV, BLOCK, DEC_ARCH`. `BLOCK` and `DEC_ARCH`
come after `RS_LV`, so a v1.0.0 instantiation by position still builds the BLOCK=128 IP. Use named parameters in new
code. The template above builds engine A256 for ASIC. For the FPGA default build (engine T), set `TARGET("FPGA")`,
`SBOX_IMPL("BRAM")` and `BLOCK(128)` (`RKS_IMPL` and `DEC_ARCH` are then ignored); with `BLOCK(256)` the same settings
build engine T256.

## 3. Parameters

| Parameter | Default | Legal Range | Recommended | Description |
|---|---|---|---|---|
| `DIR` | `"BOTH"` | ENC, DEC, BOTH | the direction(s) you need | ENC/DEC builds are smaller; ENC forces CSR.MODE = 0, DEC forces 1 |
| `TARGET` | `"FPGA"` | FPGA, ASIC | ASIC (product) / FPGA (PoC) | selects the implementation family |
| `SBOX_IMPL` | ASIC → `"LOGIC"`, FPGA → `"BRAM"` | BRAM (FPGA only), LOGIC, LUT (alias) | FPGA: **BRAM**; ASIC: LOGIC (only legal value) | FPGA + BRAM = engine T (BLOCK=128, 8 RAMB36) or T256 (BLOCK=256, 32 RAMB36). FPGA + LOGIC = engine A / A256 on LUTs, legal for every build; the flagged builds (`datasheet.md` ⚑) fall below the published baseline → use BRAM there |
| `PROFILE` | `"TCVN2024"` | TCVN2024, IETF2026 | TCVN2024 unless your system uses the IETF round counts | R = 6/7/8 vs 7/8/9 for both block sizes (there is no published IETF2026 MKV-128 128/128 vector; that case is checked against the golden model only) |
| `KEY_SCHED` | `"INT"` | INT, EXT | INT for the simplest software; EXT for the smallest ASIC area | EXT: software computes and loads the 2R+1 round keys, with no key-schedule hardware |
| `RKS_IMPL` | `"FF"` | FF, LATCH, MACRO | ASIC: LATCH (the area optimum in the proxy) if your flow times latches; FF for full scan; MACRO with a foundry RF compiler | ignored for FPGA (LUTRAM) |
| `RS_LV` | 0 | 0 or 1 | match your reset | reset active level (0 = active-low) |
| `BLOCK` | 128 | 128, 256 | the block size your protocol uses | 128 = MKV-128 (identical to v1.0.0 except INFO[7:0]); 256 = MKV-256. Changes the data width (128 / 256), the UPI address width (4 / 5) and the key words (MK0–MK7 / MK0–MK15) |
| `DEC_ARCH` | `"JDOM"` | JDOM, SEP (case-sensitive) | **JDOM** for every build | engine A256 decryption form. JDOM is smaller (6.2–8.4 kGE in the ASIC proxy) with identical ports and timing; SEP is the reference form. Ignored for BLOCK=128, for engine T256 and for `DIR="ENC"`. Not reported in INFO |

An illegal value fails elaboration on an undefined module named `vb_mkv_illegal_param_<NAME>` (`..._ASIC_BRAM` for
ASIC + BRAM). `DEC_ARCH` is checked in every build, including where it is ignored.

## 4. Clocking and reset

- **Single clock** `clk`. All logic is in one clock domain: there is no internal CDC and no second clock to constrain.
  The ASIC round-key store gates row clocks internally (`vb_icg`, §9); those are derived from `clk`.
- **Synchronous reset, active-low by default.** `rst_n` asserts reset when `rst_n == RS_LV`. With the default
  `RS_LV = 0`, drive `rst_n` low to reset. Drive the reset at the IP's own `RS_LV` level; do not assume a polarity.
- **Reset sequence:** hold `rst_n` asserted for at least 1 `clk` edge, then deassert synchronously. The suite verifies
  1- and 8-cycle pulses at idle, mid-block and mid-setup (BLOCK=128: tb_508, tb_509, tb_510; BLOCK=256: tb_020, tb_521,
  tb_522).
- **After reset:**
  - CSR, DCNT, LAT, every MK word and RKIDX read 0 (CSR = 1 for `DIR="DEC"`);
  - INFO reads the build word;
  - `din_ready` = 0 and `dout_valid` = 0 until the first key setup completes.

  Datapath registers and the round-key store are not cleared; their contents are never used before a completed setup.
- **Frequency:**
  - FPGA, `xc7k160tfbg676-3`: BLOCK=128 engine T rated 296 MHz; BLOCK=256 engine T256 rated 225 MHz (see §10).
  - ASIC: no sign-off timing exists. The proxy reg-to-reg delay is 1.08–1.50 ns at BLOCK=128 and 1.32–1.72 ns at
    BLOCK=256 (Nangate45 typical, ideal clock tree).

## 5. Register / CPU-bus interface

The IP is configured and observed over a **native UPI** CPU bus (`s_upi_*`). Protocol:

- One **write** happens in every cycle with `s_upi_we` = 1, to word address `s_upi_addr` with data `s_upi_din`. Holding
  `s_upi_we` high for N cycles performs N writes. For CSR that means N key-setup starts.
- One **read** happens in every cycle with `s_upi_oe` = 1. The data appears on `s_upi_dout` in the **next** cycle and is
  held until the next read. The address is **not latched**: present it in the `s_upi_oe` cycle. There are no wait states.
- Addresses are **word** addresses: 4 bits (16 × 32-bit registers) at BLOCK=128, 5 bits (32 × 32-bit registers) at
  BLOCK=256. A byte-addressed host bus (AXI4-Lite / APB) needs a bridge that maps byte address `A` to
  `s_upi_addr = A[5:2]` (BLOCK=128) or `A[6:2]` (BLOCK=256), issues one strobe per access and returns `s_upi_dout` one
  cycle later. No bridge ships in `rtl/`. The verification bench used an AXI4-Lite → UPI adapter that is bench-only.
- **Read side effects:** reading CSR (0x00) clears CFG_DONE and ERR; reading DCNT (0x01) clears the counter. Do not let
  a bus monitor or debugger issue speculative reads to those addresses.

Full address map, fields, access types and reset values: **`register_reference.md`**. The **ordered register
sequences** for each operating scenario (what to write, in what order, what to poll) are in **`programming_guide.md`**.
Note the read-to-clear bits flagged there: an accumulate-on-read poll is required.

## 6. Data interfaces

### 6.1 Input stream `din_*`

- **Protocol:** a transfer happens on a rising edge with `din_valid && din_ready`. The source must hold `din_valid`
  and `din_data` stable until the transfer, and `din_valid` must not depend combinationally on `din_ready`. Block
  byte order: B[0] (the first byte as printed in the test vectors) in `din_data[BLOCK-1:BLOCK-8]`.
- **Back-pressure:** `din_ready` is 0 while no key is loaded, from the cycle after any CSR write until that setup
  completes, while a block is being processed, and while the output register is still held. It depends only on
  registered state, never combinationally on `dout_ready` or `din_valid`.

### 6.2 Output stream `dout_*`

- **Protocol:** `dout_valid` and `dout_data` are registered. A transfer happens on a rising edge with
  `dout_valid && dout_ready`. While `dout_valid && !dout_ready` the output is held stable; the core finishes the next
  block and then stalls in its last cycle. No block is ever dropped or duplicated, and output order equals input order.
- **Latency:** input transfer in cycle t → `dout_valid` first high in cycle **t + 2R + 1** (exact, with no stall), on
  every engine. With `din_valid` = `dout_ready` = 1 continuously, a new block is accepted every **2R** cycles: 12/14/16
  (TCVN2024) or 14/16/18 (IETF2026) for KLEN 0/1/2. LAT (0x03) reports R, 2R and 2R+1 for the loaded key.

### 6.3 Key / mode change while streaming

A CSR write in cycle t:
- blocks transferred in cycles ≤ t finish with the **old** key and mode, and are delivered in order;
- `din_ready` = 0 from t+1 until the new setup completes;
- the setup starts once no old block is still being processed. An output held by back-pressure may stay held.

Rekeying is therefore not hitless: plan for a gap of the setup length plus up to one block.

## 7. Bring-up checklist

1. Compile `rtl/` + `rtl/lib/` with `vb_mkv_top` as top. Confirm a clean elaboration; an illegal parameter shows up as
   an unresolved `vb_mkv_illegal_param_*` module.
2. Apply clock and reset (§4).
3. Read INFO (0x02). It must equal the build word, for example:
   - `0x0000_0604` for the default build (BOTH / FPGA / BRAM / TCVN2024 / INT, BLOCK=128);
   - `0x0000_4604` for the same build with BLOCK=256 (engine T256);
   - `0x0000_1204` for BOTH / ASIC / LOGIC / TCVN2024 / INT, BLOCK=128.

   Read CSR, DCNT and LAT: they must be 0 (CSR = 1 for `DIR="DEC"`). Software written for v1.0.0 that checks
   INFO[7:0] == 0x03 must accept 0x04.
4. Load test vector #1 (`programming_guide.md` §3.1):
   - BLOCK=128: key `0102030405060708090A0B0C0D0E0F11`, plaintext `112233445566778899AABBCCDDEEFF00`. Expect ciphertext
     `B331228334C3F81A37206591498756A1` (TCVN2024) and DCNT = 1.
   - BLOCK=256 (KLEN = 0, 256-bit key): key `0102030405060708090A0B0C0D0E0F1112131415161718191A1B1C1D1E1F2223`,
     plaintext `112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00`. Expect ciphertext
     `CF2F2C1008186A578FE5B45DBD154473940C2BEC5682CDF83A3564A72DB0161B` (TCVN2024).
5. Configure for your use case, then enable data flow.

## 8. Software-visible behaviour an integrator must design for

- **INT master-key lock:** from the cycle after a CSR write until the setup completes, writes to MK0–MK7 (and MK8–MK15
  at BLOCK=256) are ignored and set ERR. Firmware must write all key words **before** the CSR write, and the next key
  only after CFG_DONE.
- **CSR write = key setup:** every CSR write restarts the key setup, even one that rewrites the same value. Do not use
  read-modify-write on CSR to change MODE unless a setup is intended.
- **Key-setup gap:**
  - INT: ≤ 10R+12 cycles from `cfg_vld`, the cycle after the CSR write (102 for R = 9), plus up to one in-flight block;
  - EXT: software-paced, then ≤ 2R+4 cycles after the last commit.
- **EXT staging width:** the staging round key is MK0–MK3 (128 bits) at BLOCK=128 and MK0–MK7 (256 bits) at
  BLOCK=256. MK4–MK7 are reserved in a BLOCK=128 EXT build but writable staging words in a BLOCK=256 EXT build.

## 9. ASIC integration notes (product target)

- **Clock gates.** `rtl/lib/vb_icg.v` is a behavioural latch + AND gate. For implementation, define `VB_ICG_CELL=<cell>`
  (ports `CK`, `E`, `SE`, `GCK`) to use your library ICG; `VB_ICG_NANGATE45` selects Nangate45 `CLKGATETST_X1`. `SE` is
  tied 0 inside `vb_sdp_ram_pp`; connect it to scan enable for DFT. CTS must balance the gated row clocks.
- **`RKS_IMPL="LATCH"`:** a latch register file. STA must time the latches (write data set up to the closing clk edge;
  staging-flop clk→Q > latch hold). The array is not scannable, so DFT needs bypass/BIST or `RKS_IMPL="FF"`.
- **`RKS_IMPL="MACRO"`:** replace `rtl/lib/vb_sdp_ram_macro.v` with a wrapper of your compiled RF/SRAM. The
  wrapper keeps the module name and ports, or you set `` `VB_SDP_RAM_MACRO_NAME``. Alternatively, define
  `VB_SDP_RAM_MACRO_BLACKBOX`. Required behaviour: 1W1R, one clock, synchronous read with output hold on `re = 0`,
  read-before-write. Size: depth 17 (TCVN2024) or 19 (IETF2026) × BLOCK bits (128 or 256). For BLOCK=256 a macro beats
  the LATCH store only at ≤ 4.6 µm²/bit all-in (`errata.md` E18).
- **False paths (optional).** In engines A and A256, `dec_ff` and the configure FSM's `act_mode` change only while no
  block is in flight. Their paths into the S-box / linear-layer arms may be constrained as false paths.
- **No ASIC sign-off data ships.** The area and timing in `datasheet.md` are a yosys + Nangate45 proxy.

## 10. Constraints (FPGA)

- **Clock.** Rated frequencies of the full IP on `xc7k160tfbg676-3`, post-route, setup and hold clean, out-of-context:
  - **BLOCK=128 (engine T): 296 MHz (3.378 ns) for both KEY_SCHED modes**, with the §11.1 recipe. The v1.0.0 claim
    "INT also 300 MHz" is not made for v1.1.0 (−12 ps on this RTL). 309 MHz is not reached post-route. The default
    implementation flow misses 296 MHz.
  - **BLOCK=256 (engine T256): 225 MHz (4.444 ns) for both KEY_SCHED modes**, with the §11.2 recipe. The BOTH builds
    pass with only 9–14 ps (top level, EXT) of margin.
  - Engines A / A256 on LUTs carry no rating (benchmark figures in `datasheet.md`).

  Your result depends on placement and on the logic around the IP. Your I/O paths are your own: the sign-off is
  reg-to-reg.
- **Exceptions.** No false-path or multicycle constraints are required internally (single clock domain).
- **Memory.** Engine T needs exactly 8 RAMB36 (T-box ROM, `DO_REG = 0`). Engine T256 needs exactly 32 RAMB36
  (`DO_REG = 0`). The round-key store maps to LUTRAM: about 86–88 LUTRAM at BLOCK=128 and 172 LUTRAM (43 RAM32M) at
  BLOCK=256.

## 11. Implementation strategy and sign-off recipe (FPGA, engines T / T256)

The critical path is the T-box loop, RAMB36 → LUT → RAMB36 address. Its route delay dominates, so placement decides
timing. The project's own implementation script is not published; the Tcl below reproduces the flow it ran.

### 11.1 BLOCK=128, engine T (296 MHz)

Signed off on the full IP (release gate G1, `errata.md`), re-run on the v1.1.0 RTL.

1. **Pblock.** Confine the `vb_mkv_core` instance (`icore` inside `vb_mkv_top`) to **one clock region** that holds its
   8 RAMB36. If the 8 BRAMs straddle a region boundary, clock skew of −0.25 to −0.30 ns costs 10–20 MHz.
2. **Directives.**
   - `place_design -directive ExtraTimingOpt`;
   - `phys_opt_design -directive AggressiveExplore`;
   - `route_design -directive Explore`.
3. **Constraint.**
   - INT: implement over-constrained at **3.236 ns**, then sign off the routed design at **3.378 ns** (296 MHz).
   - EXT: implement and sign off at **3.378 ns** (296 MHz).

```tcl
# XDC (adjust the hierarchy and the clock region to your floorplan)
create_clock -period 3.236 -name clk [get_ports clk]     ;# INT implementation (EXT: 3.378)
create_pblock pb_core
add_cells_to_pblock pb_core [get_cells <your_inst>/icore]
resize_pblock pb_core -add {CLOCKREGION_X0Y1:CLOCKREGION_X0Y1}   ;# xc7k160t region used in the signed-off runs

# implementation (Tcl / project strategy)
opt_design
place_design    -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design    -directive Explore

# sign-off at the rated period (INT over-constrained flow)
create_clock -period 3.378 -name clk [get_ports clk]     ;# 296 MHz
report_timing_summary
```

Signed-off runs:

| Build | Flow | Timed at | WNS (ns) | WHS (ns) | Result |
|---|---|---|---|---|---|
| INT | recipe (implemented at 3.236 ns) | 3.378 ns | +0.033 | +0.087 | 296 MHz met |
| INT | recipe (implemented at 3.236 ns) | 3.333 ns | −0.012 | +0.087 | 300 MHz not met |
| EXT | recipe (implemented at 3.378 ns) | 3.378 ns | +0.024 | +0.108 | 296 MHz met |

### 11.2 BLOCK=256, engine T256 (225 MHz)

1. **Directives.** The same three directives as §11.1 (ExtraTimingOpt is the required one).
2. **Pblock.** Optional. With the v1.0.0 pblock (`icore` → `CLOCKREGION_X0Y1`, which holds the 32 RAMB36 and 43 RAM32M)
   the design still passes, but the margin is not better: INT +0.051 vs +0.081 ns, EXT +0.009 vs +0.014 ns.
3. **Constraint.** Implement and sign off at **4.444 ns** (225 MHz). Judge the rating on a run constrained at 4.444 ns,
   not on 1/(T − WNS) of an over-constrained run.

```tcl
create_clock -period 4.444 -name clk [get_ports clk]     ;# 225 MHz
opt_design
place_design    -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design    -directive Explore
report_timing_summary
```

Signed-off runs (with and without the pblock):

| Build | Flow | WNS (ns) | WHS (ns) | Result |
|---|---|---|---|---|
| INT | ETO, no pblock | +0.081 | +0.064 | 225 MHz met |
| INT | ETO + pblock | +0.051 | +0.113 | 225 MHz met |
| EXT | ETO, no pblock | +0.014 | +0.066 | 225 MHz met |
| EXT | ETO + pblock | +0.009 | +0.066 | 225 MHz met |

Hold is clean in all of these runs. Because the BOTH builds have almost no guard band, **re-check timing after any
change** to the RTL around the IP, the tool version, the part or the floorplan.
