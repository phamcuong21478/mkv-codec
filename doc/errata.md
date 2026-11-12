# vb_mkv Errata & Known Limitations — v1.1.0

- **Status:** **RELEASE** (all release gates met; see § Release gate)
- **Date:** 2026-11-11

This is the honest record of what is **not** fully closed in this release. An empty section says "None" explicitly
rather than being left out. Errata ids E1–E16 keep their v1.0.0 numbers; E17–E28 are new in v1.1.0.

## Release gate

All release gates are met, so v1.1.0 is stamped **RELEASE**. No RTL gate is open: the Verilator co-simulation
regression passes with FAILED = 0 on every applicable row, and no RTL bug is open.

| Gate | Status | Detail | Action to close |
|---|---|---|---|
| G0 Tests (Verilator co-simulation) | **MET** | BLOCK=128 INT 63/63; EXT 55/55 applicable (the 8 INT-only rows fail by specification, identical to the v1.0.0 baseline); BLOCK=256 720/720 over 20 builds; config matrix 173 entries 3793 PASS / 0 FAIL, 11/11 illegal rejected; cross-checks clean (`verification_report.md`). Open RTL bugs: 0 | — |
| G1 Post-route timing on the target device | **MET** | `xc7k160tfbg676-3`, Vivado 2023.2, full IP `vb_mkv_top`, setup **and** hold clean. **BLOCK=128 (engine T): rated 296 MHz** for INT (WNS +0.033, WHS +0.087, implemented at 3.236 ns and signed off at 3.378 ns) and EXT (WNS +0.024, WHS +0.108 at 3.378 ns), with the v1.0.0 pblock + ExtraTimingOpt recipe. **BLOCK=256 (engine T256): rated 225 MHz** for INT (WNS +0.081, WHS +0.064) and EXT (WNS +0.014, WHS +0.066) at 4.444 ns with ExtraTimingOpt, no pblock (rating set by project decision). Details in `datasheet.md` § Performance. **Scope of the evidence:** out-of-context, reg-to-reg (I/O paths depend on the integrator's context and are not analysed); DIR=BOTH at the top level (the six T256 DIR × KEY_SCHED core rings also pass at 4.444 ns); one sign-off run per build. The recipe is **required**; see E2 and E19 for the margins | follow `integration_guide.md` §11 |
| G2 License | **MET** | MIT License, "Copyright (c) 2026 Cuong T.Pham" (project decision of 2026-11-09), in `LICENSE.txt`; the same license as v1.0.0 | — |
| G3 Version number | **MET** | version **1.1.0**, an additive release over 1.0.0 (project decision of 2026-11-11) | — |
| G4 Coverage | **MET** | union of 10 builds: line 98.9 % (≥ 90 %), toggle 96.4 % (≥ 80 %), functional 75/75 (`verification_report.md` § Coverage) | — |
| G5 Lint | **MET** | `Lint status: PASS`: Verilator 281/281 builds, Vivado 7/7 builds; illegal traps 12/12 (`verification_report.md` § Lint). verible is not part of the gate (project decisions of 2026-11-09 / 2026-11-11) | — |
| G6 Register reference | **MET** (single-source) | `register_reference.md` is rendered from the design documentation's register chapters, which an automated drift check compares with `rtl/vb_mkv_reg.v`: 0 mismatches | — |

## Known issues

| # | Area | Description | Severity | Workaround |
|---|---|---|---|---|
| E1 | Performance (FPGA LOGIC, BLOCK=128) | **Flagged LUT builds.** `TARGET="FPGA"` + `SBOX_IMPL="LOGIC"` (engine A on LUTs) is legal for every combination (design decision). Three builds fall below the 5.93 Mbps/Slice MKV-128 baseline at k = 128 (`datasheet.md` [R1] Tables 21–22): **A BOTH EXT 4.39, A DEC INT 3.90, A BOTH INT 3.68** | performance only | use engine T (`SBOX_IMPL="BRAM"`) for those combinations |
| E2 | Timing (FPGA, BLOCK=128) | **Rated 296 MHz for INT and EXT; "INT also 300 MHz" (v1.0.0) is withdrawn.** On the v1.1.0 RTL the INT re-time at 3.333 ns misses by 12 ps (3 endpoints, the same 1-LUT BRAM → BRAM path). Utilisation is identical to v1.0.0 and EXT reproduces v1.0.0 to the picosecond. The cause is placement noise around the changed shell netlist (INFO constant 0x03 → 0x04); no seed or directive retry was run. 309 MHz is not reached post-route; the default implementation flow misses 296 MHz | performance only | rate BLOCK=128 designs at 296 MHz; always use the `integration_guide.md` §11.1 recipe |
| E3 | Timing / area (ASIC) | **ASIC figures are a proxy, not sign-off,** at both block sizes. yosys 0.70 + ABC, Nangate45 typical; flat GE ±3 %; reg-to-reg NLDM with an ideal buffer tree; no wire load, no setup/hold, no place-and-route, no corners, no power | product-level risk | run your own synthesis, STA and P&R with your library before committing to frequency or area |
| E4 | ASIC integration | `rtl/lib/vb_icg.v` is a behavioural latch-based clock gate, and `rtl/lib/vb_sdp_ram_macro.v` is a behavioural stand-in for an RF macro. The latch RF (`RKS_IMPL="LATCH"`) is not scannable and needs latch-aware STA. Neither real ICG cells nor a real macro were simulated | integration | map `VB_ICG_CELL` to your ICG; replace the macro stub; use `RKS_IMPL="FF"` where full scan is required (`integration_guide.md` §9) |
| E5 | Verification | The one multi-cycle SVA property (`e2e_progress_bound`, `SVA_ASSERT_SEQ`) is compiled out under Verilator, so the Verilator regression never exercises it. It **is** xsim-checked on engines A and T (v1.0.0) and now on four BLOCK=256 builds (A256 JDOM, A256 SEP, T256 BOTH INT, T256 ENC EXT): positive PASS with 0 ASSERT, negative control FIRED (`verification_report.md` § Assertions) | low | covered functionally by the cycle-exact testcases (tb_103 / tb_107, tb_113_b256) as well |
| E6 | Verification | UPI read latency = 1 cycle, address-not-latched and the exact `cfg_vld` timing are not observable through the bench's AXI bridge. They are checked by SVA only | low | — |
| E7 | Verification | No gate-level (post-synthesis / post-route netlist) simulation was run for either block size | medium | run the published KATs on your netlist |
| E8 | Benchmark report | The specification asks for a standalone Kintex-7 vs. baseline benchmark report; none was produced. The MKV-128 and MKV-256 baseline comparisons are in `datasheet.md` § Performance | documentation | — |
| E9 | Behaviour (unspecified in spec) | Blocks already in flight when KLEN = 3 is written mid-stream finish with the old key (the suite assumes OP-4 applies; tb_301 and the RTL agree). The spec does not state this explicitly | low | do not rely on in-flight blocks across a rejected configuration |
| E10 | Behaviour | Rekeying is not hitless. `din_ready` = 0 from the CSR write until the new setup completes (INT ≤ 10R+12 cycles plus ≤ 1 block; EXT software-paced plus ≤ 2R+4) | by design | schedule key changes between bursts |
| E11 | Behaviour (INT) | MK lock: an MK write (MK0–MK7; MK8–MK15 at BLOCK=256) during a key setup is ignored and sets ERR. A CSR restart during a setup reuses the locked (old) MK | by design | write the MK words before the CSR write; write the next key only after CFG_DONE |
| E12 | Algorithm vectors | MKV-128: there is no independent published vector for IETF2026 128/128 (R = 7); that case is checked against the golden model only. MKV-256: the 6 published KATs are the independent vectors; there are no published round traces, and the raw 256-bit store-image references are model-generated, not independent. The J-domain decryption form (`DEC_ARCH="JDOM"`) was derived in this project, not taken from the spec; it is verified against the spec model (6 KATs + 200 random, negative control fails) and against SEP by lockstep | low | — |
| E13 | Lint scope | Vivado lint ran on 7 builds (one per engine branch, FPGA and ASIC). All 281 legal builds were linted by Verilator `-Wall`. verible house-style lint was not run (not part of the gate) | low | — |
| E14 | (v1.0.0) | Closed in the v1.0.0 cycle (testbench / text fixes after the v1.0.0 release, RTL unchanged). Kept only so that the ids stay stable | closed | — |
| E15 | Area (optimisation leads) | Dead or constant logic found by coverage analysis (in the BLOCK=128 and BLOCK=256 engines), e.g. the EXT input bundle tied 0 in INT builds of `kx_t` / `kx_t256`, the INT key-schedule hooks in EXT builds. Synthesis is expected to sweep them, but this is not confirmed in every netlist. Not a functional defect | low (area) | — |
| E16 | Verification collateral (informational) | The verification environment is not published in this repository: the Verilator + C++ co-simulation bench and its testcases, the golden models, the SVA observers and bind files, and the SVA self-check / negative-control harness. They stay in the development repository; their results are quoted in `verification_report.md` | informational | use the KAT waveform bench in `tb/` (Vivado xsim) as a starting point, and extend it with the sequences in `programming_guide.md` |
| E17 | **Erratum to v1.0.0 (documentation)** | The v1.0.0 design document (full-IP exploration table, the pblock + ExtraTimingOpt rows) prints **302.2 MHz (INT) / 297.5 MHz (EXT)**. The correct values, 1000 / (3.236 − WNS) with the rows' own WNS (−0.081 / −0.120 ns), are **301.5 / 298.0 MHz**. No conclusion changes: the v1.0.0 rating and every sign-off number were unaffected. The project's synthesis report is corrected; the v1.0.0 release is frozen and is not edited | documentation | read 301.5 / 298.0 MHz |
| E18 | Area (ASIC, `RKS_IMPL="MACRO"`) | **RF-macro numbers for BLOCK=256 are estimates only.** No RF compiler, `.lib` or LEF is available. Measured: the store alone is 17×256 FF 33 768 / LATCH 25 063 GE (19×256: 37 911 / 28 454 GE); a macro beats the LATCH store only at **≤ 4.6 µm²/bit** all-in (17×256; 4.67 µm²/bit for 19×256) and the FF store at ≤ 6.18 µm²/bit. The quoted core savings (16–35 % vs LATCH) assume 1.5–3.0 µm²/bit, TCQ 400 ps, setup 150 ps — not from a datasheet. MACRO is not characterised at BLOCK=128 either | product-level risk | obtain a real 17×256 / 19×256 1R1W macro quote (area, access time, setup) before choosing MACRO; FF / LATCH are the measured options |
| E19 | Timing (FPGA, BLOCK=256) | **T256 225 MHz rating has almost no guard band on BOTH builds.** Full IP at 4.444 ns: INT +0.081 ns, EXT **+0.014 ns** (+0.051 / +0.009 with the pblock). Core rings: BOTH EXT **+1 ps**, BOTH INT +13 ps; ENC / DEC builds +68…+88 ps. PASS today, but fragile to RTL, tool, part or floorplan changes | performance risk | always use ExtraTimingOpt (`integration_guide.md` §11.2; a pblock is optional and does not improve the margin); re-check timing after any change |
| E20 | Performance (FPGA LOGIC, BLOCK=256) | ⚑ **A256 SEP BOTH INT on LUTs is below the published MKV-256 baseline (`datasheet.md` [R1] Table 23):** BLOCK=256, `SBOX_IMPL="LOGIC"`, `DIR="BOTH"`, `KEY_SCHED="INT"`, `DEC_ARCH="SEP"` gives **1.93** Mbps/Slice < 1.98 at k = 256 (0.97×; above at k = 384 / 512). Legal but not recommended. A256 SEP DEC INT passes by only 1.5 % (2.01) | performance only | use `DEC_ARCH="JDOM"` (2.39) or `SBOX_IMPL="BRAM"` (T256: 4.34 best run, 3.81 at the rating) |
| E21 | Verification depth (BLOCK=256) | The four coverage gap-closure testcases **tb_023, tb_207, tb_312, tb_527 (`_b256_`)** passed in the six BLOCK=256 coverage builds (240/240 with `ASSERT=1`) but were added after the 173-entry config-matrix run, so they have **not** been run across the full matrix. They are queued for the next matrix run | low | — |
| E22 | Feature scope | **2-block interleave / multi-channel operation is not in v1.1.0.** One block is in flight per IP instance. The interleaved T256 variant (BRAM DO_REG = 1 with two blocks in flight) is deferred to a future version (project decision) | scope | instantiate several IPs for more throughput |
| E23 | Compatibility (BLOCK=128) | INFO[7:0] reads **0x04** in every build, including BLOCK=128 (v1.0.0: 0x03). It is the only visible difference of a BLOCK=128 build from v1.0.0 | low | software that checks INFO[7:0] == 0x03 must accept 0x04; INFO[14] = 0 identifies BLOCK=128 |
| E24 | Software visibility | `DEC_ARCH` is not reported in INFO (INFO[31:15] = 0), nor is `RKS_IMPL` | informational | identify the build from your netlist / build tag; both DEC_ARCH values have identical ports, timing and function |
| E25 | Behaviour (BLOCK=256 EXT) | In a BLOCK=256 EXT build, **MK4–MK7 are writable** staging words (the 256-bit staging key is MK0–MK7) and MK8–MK15 are reserved. In a BLOCK=128 EXT build MK4–MK7 stay reserved (intended deviation from a uniform map) | by design | follow `register_reference.md` per block size |
| E26 | Performance (FPGA LOGIC) | Engines A / A256 on LUTs (`SBOX_IMPL="LOGIC"`) have **no FPGA frequency rating**. Their datasheet Fmax values are single-run benchmark figures (A256: 234.2–296.4 MHz at a 3.500 ns constraint). The one routed A256 top-level run (LOGIC JDOM BOTH INT) met 4.444 ns with +0.174 ns, but that is not a rating | informational | use the FPGA default `SBOX_IMPL="BRAM"` when a rated frequency is required |
| E27 | Power | All power figures are **vectorless** Vivado estimates (default activity: static probability 0.5, toggle rate 12.5 %; confidence Medium), not workload measurements. Figures in `datasheet.md` § Power. No ASIC power figure exists | informational | run a SAIF-based estimate with your workload |
| E28 | Published content | The header of `rtl/lib/vb_sdp_ram_pp.v` (a reused library module) names a personal email address in the verified source. Release policy allows no email address in the deliverables, so in this repository that single comment line reads `// Email        : (removed from the release copy)`. The file is otherwise byte-identical to the verified source, and no code line changed. The v1.0.0 release still carries the original line; it is frozen and is not edited | informational | — |

## Coverage waivers

These are from the project's coverage report and apply to both block sizes.

| Item (file:line / cover point) | Metric | Justification |
|---|---|---|
| W1 `rtl/vb_mkv_cfg.v:70`, `rtl/vb_mkv_seq_t.v:71` (reused unmodified by T256), `rtl/vb_mkv_sbox_logic.v:69` (reused by A256) (`default:` arms) | line / branch | fully decoded encodings: every reachable value has an explicit arm, so the `default` is defensive code kept per coding style. FSM-legal SVA invariants prove the states stay legal |
| W2 parameter-constant branches (`vb_mkv_reg` DIR / KEY_SCHED arms incl. `vb_mkv_reg.v:164`; `rtl/lib/vb_sdp_ram_pp.v:125` with `ld` = 1; the same applies to `vb_mkv_round_t256`) | branch | elaboration constants. Every parameter value is built and run in the 173-entry matrix; the lib RAM keeps its general read enable for other users |
| W3 `vb_mkv_reg.rf_dcnt_ff[31:11]` | toggle | 32-bit clear-on-read counter: toggling the top bits needs ≥ 2³¹ accepted blocks, which is infeasible in simulation. Increment and read-restart are covered |

## Unverified configurations

| Verified configurations | Parameters |
|---|---|
| Full BLOCK=128 63-row suite (INT 63, EXT 55 applicable) | BLOCK=128, DIR=BOTH, TARGET=FPGA, SBOX_IMPL=BRAM (engine T), PROFILE=TCVN2024, KEY_SCHED=INT and EXT, RS_LV=0 |
| Full BLOCK=256 36-row suite (720 runs) | 20 builds, all DIR × KEY_SCHED where listed: ASIC A256 JDOM ENC / DEC / BOTH × INT / EXT; ASIC A256 SEP DEC / BOTH × INT / EXT; FPGA LOGIC A256 BOTH × JDOM / SEP × INT / EXT; FPGA BRAM T256 ENC / DEC / BOTH × INT / EXT |
| BLOCK=128 36-row matrix subset (1436 runs) | all 60 legal BLOCK=128 builds, `"LUT"` alias ×2, RS_LV=1 ×2, plus one BLOCK=128 `DEC_ARCH="SEP"` build (33 rows). ASIC LATCH / MACRO store builds run the smoke / vector / store-image rows only |
| BLOCK=256 matrix list (2324 runs) | all 92 legal BLOCK=256 builds + LUT alias, RS_LV=1 T256, RS_LV=1 A256 SEP, T256 with `DEC_ARCH="SEP"`, ENC with `DEC_ARCH="SEP"`. ASIC LATCH / MACRO store builds run the unfiltered rows only (reset, INFO/LAT, KAT, cycle-exact, store image, EXT order, cross-engine digest, S-box lanes, EXT commit / dropped commit). Random stress runs on DIR=BOTH, FF-store, RS_LV=0 builds only |
| BLOCK=128 port trace vs v1.0.0 | 66 builds × 2 000 000 cycles (all 60 legal + LUT ×2 + RS_LV=1 ×2 + `DEC_ARCH="SEP"` ×2) |
| Coverage-instrumented suites | 10 builds (T, A, T256, A256 JDOM, A256 SEP × INT / EXT); the BLOCK=256 ones record verdicts (240/240) |

Not yet verified:
- the BLOCK=128 rows outside the matrix subset on any build other than the engine-T default builds: tb_001, 003,
  005–008, 010, 011, 102, 201–203, 301, 302, 403, 404, 501, 502, 504–507, 511–515 (unchanged from v1.0.0);
- the BLOCK=256 rows filtered `@rks=FF` on ASIC LATCH / MACRO store builds, and the random-stress rows on DIR ≠ BOTH
  or RS_LV=1 builds;
- the four BLOCK=256 gap rows across the full matrix (E21);
- RS_LV=1 beyond the 2 BLOCK=128 and 2 BLOCK=256 matrix builds (plus 1 RS_LV=1 lockstep pair);
- `RKS_IMPL="MACRO"` with a real compiled macro (behavioural stub only);
- any gate-level netlist.

The IP is designed to be correct for these combinations (the parameters change structure, not the cycle contract),
but an integrator using them should add coverage.

## Scope notes

- Single clock domain: no CDC analysis applies. The ASIC store's gated row clocks derive from `clk`.
- Coverage was measured with free tools (Verilator); see `verification_report.md` for the exact measured and
  not-measured scope.
- This repository contains the RTL, the six documents in `doc/` and a KAT waveform bench for Vivado xsim (`tb/`). The
  bench runs the published test vectors on 14 configurations; it is a demonstration and smoke bench, not the sign-off
  suite. No Vivado IP-catalog packaging script or example wrapper is provided; add the `rtl/` files to your project
  directly (`integration_guide.md` §1).
- No ASIC collateral (netlist, liberty, LEF, DFT) is provided, even though ASIC is the product target.
- The full design document, the per-module documents and the synthesis, coverage, lint and SVA reports stay in the
  development repository (see also E16). The documents in `doc/` quote their results and are self-contained for
  integration and programming.
