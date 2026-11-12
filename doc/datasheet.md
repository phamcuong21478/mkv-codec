# vb_mkv Datasheet — v1.1.0

- **Status:** **RELEASE** (all release gates met; see `errata.md` § Release gate)
- **License:** MIT, Copyright (c) 2026 Cuong T.Pham (`LICENSE.txt`)
- **Type:** soft-IP, Verilog-2005, single clock domain. Product target **ASIC**; Kintex-7 FPGA = PoC / demo
- **Date:** 2026-11-11

## Overview

`vb_mkv` is an iterative accelerator for MKV, the block cipher of the 2024 draft Vietnamese national standard (TCVN)
[R1], working in ECB. The block size is a compile-time parameter:
- **`BLOCK=128`** (default): MKV-128, with 128-, 192- or 256-bit keys;
- **`BLOCK=256`**: MKV-256, with 256-, 384- or 512-bit keys.

The key length is selected at run time. The round profile is TCVN2024 (R = 6/7/8) or IETF2026 (R = 7/8/9), chosen at
compile time; R is the same for both block sizes. With a 2-cycle round the IP accepts a new block every **2R** cycles
and delivers it after exactly **2R+1** cycles. The round keys are either computed on chip (`KEY_SCHED="INT"`) or loaded
by software (`KEY_SCHED="EXT"`); the EXT raw key format is identical for every engine of one block size.

One RTL source covers four technology-specific engines:
- **engine A** (BLOCK=128): one state register, GF(2⁴) logic S-box and SLP linear layer, for ASIC and FPGA
  `SBOX_IMPL="LOGIC"`;
- **engine T** (BLOCK=128): T-box datapath in 8 RAMB36, for FPGA `SBOX_IMPL="BRAM"`;
- **engine A256** (BLOCK=256): the logic engine at 256 bits, for ASIC and FPGA `SBOX_IMPL="LOGIC"`. Decryption runs in
  the J-domain (`DEC_ARCH="JDOM"`, default: one M8 network serves both directions) or with a separate M8⁻¹ network
  (`DEC_ARCH="SEP"`, the reference form);
- **engine T256** (BLOCK=256): T-box datapath in 32 RAMB36, for FPGA `SBOX_IMPL="BRAM"`.

## Features

- MKV-128 and MKV-256 encryption and/or decryption (`DIR` = ENC / DEC / BOTH; BOTH selects the direction per key setup).
- Run-time key length (CSR.KLEN 0/1/2 = 128/192/256 bits at BLOCK=128, 256/384/512 bits at BLOCK=256); compile-time
  round profile TCVN2024 / IETF2026.
- Streaming: interval exactly 2R and latency exactly 2R+1 on every engine. Valid/ready in and out, order preserved, no
  drop under any back-pressure, registered-only back-pressure (no `dout_ready` → `din_ready` combinational path).
- INT key setup ≤ 10R+12 cycles, counted from `cfg_vld` (the cycle after the CSR write) to the `cfg_busy` fall with an
  idle engine. Measured: engines A / A256 8R+4; engines T / T256 ENC 8R+6, DEC / BOTH-dec 66/77/86 (TCVN2024
  R = 6/7/8) and 77/86/97 (IETF2026 R = 7/8/9).
- EXT software round-key load: 2R+1 raw keys in any order, rewrites allowed, completion by index coverage. Illegal or
  dropped commits are reported in ERR.
- INT master-key lock: MK writes during a key setup (MK0–MK7, and MK8–MK15 at BLOCK=256) are ignored and set ERR, so a
  key cannot be corrupted silently.
- Sticky CFG_DONE / ERR (read-clear), accepted-block counter DCNT, INFO (version 0x04, build options, BLOCK bit),
  LAT (R, 2R, 2R+1).
- ASIC round-key store selectable: flop array, latch register file, or a foundry RF/SRAM macro (`RKS_IMPL`).
- CPU-bus (native UPI: `we`/`oe` strobes, word address of 4 bits at BLOCK=128 and 5 bits at BLOCK=256, 32-bit data,
  1-cycle read latency) register control — see `register_reference.md`.
- Synchronous reset, polarity selectable via `RS_LV` (default active-low).
- Single clock domain (no internal CDC).
- Illegal parameter values fail elaboration with a self-explaining module name (`vb_mkv_illegal_param_<NAME>`).
- `BLOCK=128` builds are cycle- and port-identical to v1.0.0 except INFO[7:0] (`errata.md` E23).

## Configuration

| Parameter | Default | Legal Range | Description |
|---|---|---|---|
| `DIR` | `"BOTH"` | `"ENC"`, `"DEC"`, `"BOTH"` | direction(s) built; ENC/DEC force CSR.MODE |
| `TARGET` | `"FPGA"` | `"FPGA"`, `"ASIC"` | implementation family; with `SBOX_IMPL` and `BLOCK` selects the engine |
| `SBOX_IMPL` | `TARGET=="ASIC" ? "LOGIC" : "BRAM"` | `"BRAM"` (FPGA only), `"LOGIC"`, `"LUT"` (deprecated alias of LOGIC) | FPGA BRAM → engine T / T256; otherwise engine A / A256 |
| `PROFILE` | `"TCVN2024"` | `"TCVN2024"`, `"IETF2026"` | round counts R = 6/7/8 or 7/8/9 |
| `KEY_SCHED` | `"INT"` | `"INT"`, `"EXT"` | on-chip key schedule or software-loaded round keys |
| `RKS_IMPL` | `"FF"` | `"FF"`, `"LATCH"`, `"MACRO"` | ASIC round-key store (ignored for FPGA, which uses LUTRAM) |
| `RS_LV` | 0 | 0 or 1 | reset active level (0 = active-low) |
| `BLOCK` | 128 | 128, 256 | block size: MKV-128 or MKV-256 (new in 1.1.0, placed after `RS_LV`) |
| `DEC_ARCH` | `"JDOM"` | `"JDOM"`, `"SEP"` (case-sensitive) | engine A256 decryption form; ignored for BLOCK=128, for engine T256 and for `DIR="ENC"` (new in 1.1.0, placed after `BLOCK`) |

Illegal: any other value, and `TARGET="ASIC"` with `SBOX_IMPL="BRAM"`. `DEC_ARCH` is checked in every build
(`vb_mkv_illegal_param_DEC_ARCH`). Legal space: **152 distinct core builds**.

| Block | Engine | Builds |
|---|---|---|
| 128 | T (FPGA + BRAM) | 12 |
| 128 | A (FPGA + LOGIC 12, ASIC 36) | 48 |
| 256 | T256 (FPGA + BRAM) | 12 |
| 256 | A256 ASIC (36 JDOM + 24 SEP) | 60 |
| 256 | A256 FPGA + LOGIC (12 JDOM + 8 SEP) | 20 |

`DEC_ARCH="SEP"` where it is ignored builds the same netlist as `"JDOM"` and is not counted; nor are the `"LUT"` alias
builds. Every legal build was regression-tested, but the depth differs per build (`errata.md` § Unverified
configurations).

## Interfaces

| Interface | Type | Direction | Description |
|---|---|---|---|
| `clk` / `rst_n` | clock / sync reset | in | single clock; reset asserted when `rst_n == RS_LV` |
| `s_upi_*` | native UPI register bus (`we`, `oe`, `addr`, `din[31:0]`, `dout[31:0]`) | slave | `addr[3:0]`, 16 words at BLOCK=128; `addr[4:0]`, 32 words at BLOCK=256. 32-bit word-addressed registers, 1-cycle read latency |
| `din_*` | valid/ready stream, BLOCK bits (`din_valid`, `din_ready`, `din_data`) | in | input blocks, byte B[0] in the most significant byte |
| `dout_*` | valid/ready stream, BLOCK bits (`dout_valid`, `dout_ready`, `dout_data`) | out | output blocks, registered |

## Performance

All numbers come from the project's synthesis and implementation runs on the v1.1.0 RTL. The BLOCK=128 core benchmark
and the engine A ASIC figures are carried over from v1.0.0, since that RTL is unchanged. The run scripts and reports
are not published in this repository. Tools: Vivado v2023.2; ASIC proxy yosys 0.70 + ABC with Nangate45 typical.
Target part: `xc7k160tfbg676-3` (Kintex-7, the specification's benchmark part; PoC target).

### Rated FPGA frequencies (full IP `vb_mkv_top`, post-route, out-of-context, reg-to-reg)

| Block | Engine | Rated frequency | Required flow (`integration_guide.md` §11) | Details |
|---|---|---|---|---|
| 128 | T (FPGA default) | **296 MHz** (3.378 ns), INT and EXT | pblock + ExtraTimingOpt; INT implemented over-constrained at 3.236 ns | § Full IP, BLOCK=128 |
| 256 | T256 (FPGA default) | **225 MHz** (4.444 ns), INT and EXT | ExtraTimingOpt placer directive, judged on a run constrained at 4.444 ns; a pblock is optional | § Full IP, BLOCK=256 |
| 128 / 256 | A / A256 on LUTs | no rating; benchmark figures only | — | § FPGA core benchmark |

The v1.0.0 datasheet also stated "INT signs off at 300 MHz" for BLOCK=128. **That is not claimed for v1.1.0**: on this
RTL the INT re-time at 3.333 ns misses by 12 ps (`errata.md` E2).

### Full IP `vb_mkv_top`, BLOCK=128 (engine T, BOTH, TCVN2024) — v1.0.0 sign-off recipe re-run on the v1.1.0 RTL

| Build | Implemented at | Timed (signed off) at | WNS / TNS (ns) | WHS (ns) | Result | Logic LUT / LUTRAM / FF / RAMB36 | Slices |
|---|---|---|---|---|---|---|---|
| INT | 3.236 ns (over-constrained) | **3.378 ns (296 MHz)** | **+0.033 / 0** | +0.087 | **MET** | 1616 / 86 / 1238 / 8 | 623 |
| INT | 3.236 ns (over-constrained) | 3.333 ns (300 MHz) | −0.012 (3 endpoints) | +0.087 | not met | same | same |
| EXT | 3.378 ns | **3.378 ns (296 MHz)** | **+0.024 / 0** | +0.108 | **MET** | 1426 / 86 / 1059 / 8 | 539 |

- Utilisation is identical to v1.0.0. The EXT build reproduces v1.0.0 to the picosecond.
- **Worst path:** RAMB36 → 1 LUT6 → RAMB36 ADDR (1.607 ns logic + about 1.28 ns route). Timing is placement-bound.
- **Power (v1.0.0, post-synth, 3.236 ns):** 229 mW total (119 dynamic + 111 static).

### Full IP `vb_mkv_top`, BLOCK=256 (engine T256, BOTH, TCVN2024) at the 225 MHz rating

Flow (`integration_guide.md` §11.2): constrained at 4.444 ns, `place_design` ExtraTimingOpt, `phys_opt_design`
AggressiveExplore, `route_design` Explore; each build was run with and without the pblock.

| Build | Flow | WNS / TNS (ns) | Failing endpoints | WHS (ns) | Fmax | Logic LUT / LUTRAM / FF / RAMB36 / RAMB18 | Slices |
|---|---|---|---|---|---|---|---|
| INT | ETO, no pblock | **+0.081** / 0 | 0 of 6471 | +0.064 | 229.2 MHz | 3552 / 172 / 2297 / 32 / 0 | 1538 |
| INT | ETO + pblock | +0.051 / 0 | 0 of 6473 | +0.113 | 227.6 MHz | 3526 / 172 / 2298 / 32 / 0 | 1302 |
| EXT | ETO, no pblock | **+0.014** / 0 | 0 of 5891 | +0.066 | 225.7 MHz | 2705 / 172 / 2000 / 32 / 0 | 1167 |
| EXT | ETO + pblock | +0.009 / 0 | 0 of 5891 | +0.066 | 225.5 MHz | 2746 / 172 / 2000 / 32 / 0 | 1060 |

- **Worst path:** BRAM → LUT5 + LUT6 → BRAM ADDR (about 1.65 ns logic + 2.0–2.4 ns route).
- **Margin:** INT +51…+81 ps; **EXT only +9…+14 ps**. In the core ring the BOTH builds pass by +1 ps (EXT) and +13 ps
  (INT). The rating has almost no guard band on BOTH builds (`errata.md` E19).
- **Throughput at 225 MHz** (256·f / 2R): 4800 / 4114 / 3600 Mbit/s for R = 6 / 7 / 8.
- The pblock does not help at BLOCK=256: it reduces slices but lengthens the BRAM-to-BRAM routes.

### Power (vectorless `report_power`, the v1.0.0 method)

Vivado default activity (input static probability 0.5, toggle rate 12.5 %), confidence Medium. These are not workload
figures (`errata.md` E27).

| Build (DIR=BOTH) | Clock | State | Total (W) | Dynamic (W) | Static (W) |
|---|---|---|---|---|---|
| BLOCK=256 T256 INT | 225 MHz | post-route, ETO | **0.388** | 0.276 | 0.112 |
| BLOCK=256 T256 EXT | 225 MHz | post-route, ETO | **0.409** | 0.297 | 0.112 |
| BLOCK=256 T256 INT / EXT | 225 MHz | post-synth | 0.343 / 0.362 | 0.231 / 0.250 | 0.112 |
| BLOCK=256 A256 LOGIC JDOM INT | 225 MHz | post-route, ETO | 0.739 | 0.627 | 0.112 |
| BLOCK=128 T INT (v1.0.0) | 309 MHz | post-synth | 0.229 | 0.119 | 0.110 |

### FPGA core benchmark, BLOCK=128 (`vb_mkv_core`, post-route ring, 3.236 ns) — unchanged from v1.0.0

Mbps/Slice = 128·f/(2R) / core slices, with f = min(309, 1000/(3.236 − WNS)) from the better of a plain and a pblock run.
Baseline = the MKV design team's published Kintex-7 MKV-128 result ([R1] Tables 21–22, encryption and decryption):
5.93 / 4.86 / 4.19 Mbps/Slice (k = 128/192/256).
**⚑ = below the 5.93 baseline**: legal by design decision, but **use engine T (`SBOX_IMPL="BRAM"`) instead**.

| Engine | Build | WNS (ns) | Achieved Fmax (MHz) | Core slices | Mbps/Slice k=128 / 192 / 256 |
|---|---|---|---|---|---|
| T | ENC EXT | −0.208 | 290.4 | 340 | **9.11** / 7.81 / 6.83 |
| T | DEC EXT | −0.107 | 299.1 | 418 | 7.63 / 6.54 / 5.73 |
| T | BOTH EXT | −0.165 | 294.0 | 444 | 7.06 / 6.05 / 5.30 |
| T | ENC INT | −0.264 | 285.7 | 454 | 6.71 / 5.75 / 5.03 |
| T | DEC INT | −0.245 | 287.3 | 506 | 6.06 / 5.19 / 4.54 |
| T | BOTH INT | −0.220 | 289.4 | 487 | 6.34 / 5.43 / 4.75 |
| A (LOGIC) | ENC EXT | +0.114 | 309 | 388 | 8.49 / 7.28 / 6.37 |
| A (LOGIC) | DEC EXT | +0.248 | 309 | 390 | 8.45 / 7.24 / 6.34 |
| A (LOGIC) | BOTH EXT ⚑ | −0.071 | 302.4 | 734 | **4.39** / 3.77 / 3.30 |
| A (LOGIC) | ENC INT | +0.153 | 309 | 527 | 6.25 / 5.36 / 4.69 |
| A (LOGIC) | DEC INT ⚑ | −0.105 | 299.3 | 818 | **3.90** / 3.35 / 2.93 |
| A (LOGIC) | BOTH INT ⚑ | −0.150 | 295.3 | 856 | **3.68** / 3.15 / 2.76 |

### FPGA core benchmark, BLOCK=256 engine T256 (`vb_mkv_core` ring, TCVN2024)

Baseline = the MKV design team's published Kintex-7 MKV-256 result (`xc7k160tfbg676-3`, [R1] Table 23, called
"Table 23" below): **1.98 / 1.63 / 1.40 Mbps/Slice** at k = 256 / 384 / 512, 1791 / 1863 / 1896 slices,
250 MHz, ≈ 39 RAMB36. "Best run" = the better of Default / ExtraTimingOpt at 3.236 ns
(over-constrained). "At rating" = 256·225 MHz/(2R) over the slices of the 4.444 ns ExtraTimingOpt rating run. ENC and DEC
are each compared with the baseline; BOTH is for information.

| Build | Best run: slices / Fmax MHz | Best run Mbps/Slice k=256 / 384 / 512 | vs Table 23 | Rating run: slices / WNS @ 4.444 ns | At-rating Mbps/Slice | vs Table 23 |
|---|---|---|---|---|---|---|
| ENC INT | 1096 / 228.2 | 4.44 / 3.81 / 3.33 | 2.24–2.38× | 1116 / +0.073 | 4.30 / 3.69 / 3.23 | 2.17–2.30× |
| ENC EXT | 941 / 226.0 | 5.12 / 4.39 / 3.84 | 2.59–2.74× | 1002 / +0.088 | 4.79 / 4.11 / 3.59 | 2.42–2.57× |
| DEC INT | 1147 / 225.0 | 4.18 / 3.59 / 3.14 | 2.11–2.24× | 1346 / +0.068 | 3.57 / 3.06 / 2.67 | 1.80–1.91× |
| DEC EXT | 969 / 219.1 | 4.82 / 4.13 / 3.62 | 2.44–2.58× | 1164 / +0.080 | 4.12 / 3.53 / 3.09 | 2.08–2.21× |
| BOTH INT (info) | 1106 / 224.8 | 4.34 / 3.72 / 3.25 | 2.19–2.32× | 1260 / +0.013 | 3.81 / 3.27 / 2.86 | 1.92–2.04× |
| BOTH EXT (info) | 979 / 224.0 | 4.88 / 4.18 / 3.66 | 2.46–2.61× | 1078 / **+0.001** | 4.45 / 3.82 / 3.34 | 2.25–2.39× |

- **Every T256 build is above Table 23 at every k:** 2.11–2.74× in the best runs and 1.80–2.57× at the rated 225 MHz.
  T256 uses fewer BRAMs (32 RAMB36 vs ≈ 39) and keeps the round-key store in LUTRAM (43 RAM32M). BRAM DO_REG = 0.
- All six builds meet 225 MHz at 4.444 ns with ExtraTimingOpt (WNS +0.001…+0.088 ns, hold clean).
- The 3.236 ns sweep Fmax values (219.1–234.0 MHz) are over-constrained figures. The rating is judged only on the
  4.444 ns runs.

### FPGA core benchmark, BLOCK=256 engine A256 on LUTs (`SBOX_IMPL="LOGIC"`, informative)

Core ring, ExtraTimingOpt at 3.500 ns, 0 BRAM, store in 43 RAM32M. A256 FPGA builds have no rating; the Fmax column is
the frequency achieved in a single run.

| Build | DEC_ARCH | Slices / Fmax MHz | Mbps/Slice k=256 / 384 / 512 | vs Table 23 |
|---|---|---|---|---|
| ENC INT | — | 1526 / 296.4 | 4.14 / 3.55 / 3.11 | 2.09–2.22× |
| ENC EXT | — | 1153 / 289.6 | 5.36 / 4.59 / 4.02 | 2.71–2.87× |
| DEC INT | JDOM | 2045 / 248.8 | 2.60 / 2.22 / 1.95 | 1.31–1.39× |
| DEC EXT | JDOM | 1214 / 293.3 | 5.15 / 4.42 / 3.86 | 2.60–2.76× |
| BOTH INT | JDOM | 2230 / 250.1 | 2.39 / 2.05 / 1.79 | 1.21–1.28× |
| BOTH EXT | JDOM | 1740 / 241.0 | 2.96 / 2.53 / 2.22 | 1.49–1.58× |
| DEC INT | SEP | 2535 / 239.4 | 2.01 / 1.73 / 1.51 | 1.02–1.08× (margin 1.5 % at k = 256) |
| BOTH INT ⚑ | SEP | 2595 / 234.2 | **1.93** / 1.65 / 1.44 | **0.97×** / 1.01× / 1.03× |

⚑ **Below baseline:** BLOCK=256, `SBOX_IMPL="LOGIC"`, `DIR="BOTH"`, `KEY_SCHED="INT"`, `DEC_ARCH="SEP"` is below
Table 23 at k = 256. It is legal but not recommended: use `DEC_ARCH="JDOM"` or the FPGA default `SBOX_IMPL="BRAM"`
(T256) (`errata.md` E20).

### ASIC proxy (product target)

**Proxy only, not sign-off.** yosys 0.70 + ABC mapped to Nangate45 typical:
- flat gate count, ±3 % from run to run;
- register-to-register NLDM delay with an ideal buffer tree;
- no wire load, no setup/hold, no place-and-route, no corner analysis.

Conditions: `vb_mkv_core` TARGET=ASIC, TCVN2024, R = 6, store DEPTH 17. Throughput = BLOCK·f/12 with f = 1/r2r.

**Engine A256 (BLOCK=256)**:

| Build | DEC_ARCH | flat kGE / r2r ps / Gbps | **Mbps/kGE** | BLOCK=128 Mbps/kGE (Δ) |
|---|---|---|---|---|
| ENC INT FF | — | 63.1 / 1317 / 16.20 | 257 | 334 (−23 %) |
| ENC INT LATCH | — | 54.0 / 1452 / 14.69 | 272 | 325 (−16 %) |
| ENC EXT LATCH | — | 50.1 / 1530 / 13.94 | 278 | 359 (−23 %) |
| DEC INT FF | JDOM / SEP | 68.6 / 1405 / 15.18 · 77.0 / 1622 / 13.15 | 221 / 171 | 229 (−3 % / −25 %) |
| DEC INT LATCH | JDOM / SEP | 60.4 / 1499 / 14.23 · 68.2 / 1561 / 13.67 | 236 / 200 | 237 (0 % / −16 %) |
| DEC EXT LATCH | JDOM / SEP | 49.4 / 1425 / 14.97 · 49.1 / 1347 / 15.84 | 303 / 322 | 343 (−12 % / −6 %) |
| BOTH INT FF | JDOM / SEP | 72.4 / 1653 / 12.91 · 80.0 / 1671 / 12.77 | 178 / 160 | 209 (−15 % / −23 %) |
| BOTH INT LATCH | JDOM / SEP | 63.8 / 1713 / 12.45 · 71.9 / 1576 / 13.54 | 195 / 188 | 241 (−19 % / −22 %) |
| BOTH EXT LATCH | JDOM / SEP | 61.7 / 1719 / 12.41 · 67.9 / 1642 / 12.99 | 201 / 191 | 240 (−16 % / −20 %) |

- **JDOM vs SEP:** JDOM is 6.2–8.4 kGE smaller than SEP in every DEC INT and BOTH build, with equal or higher
  Mbps/kGE. DEC + EXT is equal (49.4 vs 49.1 kGE; the netlists are permuted equivalents). **JDOM is recommended for
  every build**; SEP is the reference implementation and cross-check partner.
- **vs BLOCK=128:** throughput per core is +64…+95 %, area ×2.0–2.2, and Mbps/kGE −3…−25 % (JDOM).
- **Store share:** the store is 47–54 % of the 256 core with FF and 35–51 % with LATCH.

**Engine A (BLOCK=128)**, unchanged from v1.0.0 (the v1.1.0 hierarchical GE is identical in 7 of 9 builds and within
13 GE otherwise):

| Build | kGE (flat) | r2r (ps) / levels | Proxy Mbps | **Mbps/kGE** |
|---|---|---|---|---|
| ENC INT FF | 29.6 | 1080 / 18 | 9877 | 334 |
| ENC INT LATCH | 25.1 | 1308 / 16 | 8155 | 325 |
| ENC EXT LATCH | 23.2 | 1280 / 16 | 8333 | **359** |
| DEC INT FF | 34.0 | 1373 / 17 | 7769 | 229 |
| DEC INT LATCH | 30.1 | 1492 / 20 | 7149 | 237 |
| DEC EXT LATCH | 23.1 | 1350 / 19 | 7901 | 343 |
| BOTH INT FF | 35.4 | 1439 / 20 | 7413 | 209 |
| BOTH INT LATCH | 31.3 | 1416 / 20 | 7533 | 241 |
| BOTH EXT LATCH | 29.6 | 1504 / 19 | 7092 | 240 |

**`RKS_IMPL="MACRO"`** is not characterised at either block size: no RF compiler data is available. For BLOCK=256 the
measured break-even is ≤ 4.6 µm²/bit all-in against the LATCH store (17×256; 4.67 µm²/bit for 19×256) and ≤ 6.18 µm²/bit
against the FF store. Everything beyond that is an **estimate** (`errata.md` E18). EXT builds carry no key-schedule
hardware; their key cost is software.

## Verification summary

On the released RTL (identical to `rtl/` of this repository except one header comment, `errata.md` E28):
- **BLOCK=128:** INT 63/63; EXT 55/55 applicable rows (the 8 INT-only rows fail by specification, row by row as in
  v1.0.0).
- **BLOCK=256:** 20 builds × 36 rows, 720/720 PASS, no assertion fired.
- **Config matrix:** 173 entries (152 legal + 10 extra positive + 11 negative), 3793 PASS / 0 FAIL, 0 build failures;
  11/11 illegal builds rejected with the named module.
- **Cross-checks:** A256 ↔ T256 output digests identical (12 groups, 0 differing); SEP ↔ JDOM IP-port lockstep 11/11
  pairs × 1 000 000 cycles, 0 mismatches, with a negative control detected 2/2.
- **BLOCK=128 non-regression:** port-trace equivalence against v1.0.0 over 66 builds × 2 000 000 cycles, 0 mismatches
  except INFO[7:0].
- **Assertions:** 294 SVA properties and 75 cover points.
- **Coverage** (union of 10 builds): line 98.9 %, toggle 96.4 %, functional 75/75 (100 %). These are same-cycle SVA
  cover points only; no covergroups are used.
- **Lint PASS:** Verilator `-Wall` on 281/281 builds and Vivado `synth_design -lint` on 7/7 builds.

Coverage is evidence of what the suite exercised, not a proof of correctness, and was measured with free tools. See
`verification_report.md` for the exact scope.

## Deliverables

- synthesizable RTL (`rtl/`, `rtl/lib/`);
- this datasheet, the integration guide, programming guide, register reference, verification report and errata
  (`doc/`);
- a KAT waveform bench for Vivado xsim (`tb/`): the published test vectors on 14 configurations, with waveform dump;
- the license (`LICENSE.txt`).

The sign-off verification bench, the synthesis scripts and reports, and the full design document are not part of the
deliverables (`README.md`). No Vivado IP-catalog packaging script and no ASIC collateral (netlist, liberty, LEF, DFT)
are provided. ASIC integrators need their library ICG cell and, for `RKS_IMPL="MACRO"`, the RF macro wrapper
(`integration_guide.md` §9).

## References

- **[R1]** Ban Cơ yếu Chính phủ (Government Cipher Committee of Vietnam), *Thuyết minh dự thảo Tiêu chuẩn Việt Nam:
  Công nghệ thông tin – Các kỹ thuật an toàn – Các thuật toán mật mã – Mã khối MKV* (explanatory note to the draft TCVN
  "Information technology – Security techniques – Cryptographic algorithms – MKV block cipher"), Hà Nội, 2024.
  <https://datafiles.chinhphu.vn/cpp/files/duthaovbpl/2024/thuyet-minh-du-thao-tcvn-thuat-toan.pdf>.
  §3.2 gives the MKV overview. §3.7.2 gives the published Kintex-7 results: Tables 21–22 for MKV-128 and Table 23 for
  MKV-256, the baselines of § Performance.
