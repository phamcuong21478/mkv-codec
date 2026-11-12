# vb_mkv Verification Report — v1.1.0

- **Status:** **RELEASE** (all release gates met; see `errata.md` § Release gate)
- **Date:** 2026-11-11
- **RTL verified:** the v1.1.0 RTL. Every regression, matrix, coverage, lint and synthesis run below was made on it;
  later changes touched SVA observers, documentation and evidence only. It is the RTL in `rtl/` of this repository,
  except one header comment line in `rtl/lib/vb_sdp_ram_pp.v` (`errata.md` E28). `rtl/lib/` is unchanged since v1.0.0.

This report is the verification sign-off behind the release status. All numbers are quoted from the project's own
verification artifacts: the testcase list, the regression summaries and per-build results, the engine-bench results,
the coverage report, the SVA inventory and its evidence logs, the lint report and the feature trace. None are
re-derived here. Those artifacts, the bench, the golden models and the SVA observers stay in the development
repository and are not published here.

## Methodology

`vb_mkv` was verified with three layers:
- **A directed, self-checking testcase suite.** It is driven entirely through the CPU bus (UPI, through a bench-only
  AXI4-Lite adapter) and the BLOCK-bit data streams. Every testcase ends in a `[FINISH] PASS` / `[FINISH] FAIL` verdict
  token. There are 103 testcases: 63 for BLOCK=128 (unchanged from v1.0.0) and 40 for BLOCK=256 (`tb_*_b256_*`).
  Stimulus is deterministic or seeded, and the seeds are logged.
- **A Verilator + C++ co-simulation bench with golden reference models.** The MKV-128 model is a C++ port of the
  specification's Python reference model. The MKV-256 model follows the same reference model at 256 bits; its host
  selftest passes (6 KATs, 1200 random vectors, M8⁻¹ = J·M8·J). The models cross-check every output block and, white-box, the
  round-key store image. They also check the cycle contract (interval 2R, latency 2R+1, setup budgets) from monitor
  cycle stamps.
- **Bound SystemVerilog assertions.** 294 SVA properties observe the RTL. A failing assertion fails its testcase
  (`ASSERT=1` in every sign-off run).

Engine-level unit benches back the new engines:
- **A256:** 83/83 PASS over 20 builds; 20/20 mutants detected with SVA; SEP ↔ JDOM cross-check 33/33, 2 435 790 cycles,
  0 mismatches; `vb_mkv_lin_m8` / `vb_mkv_lin_m8i` and `vb_mkv_key_ld256` leaf benches PASS.
- **T256:** 36/36 PASS (12 builds × 3 traffic patterns) against a bit-exact Python model of the datapath; negative
  controls 30/30; ROM leaf 16/16 with an exhaustive check.

The RTL is plain Verilog-2005. The assertions are bound externally (`bind`) and never alter the design.

## Test results

| Suite | Tool | Builds | Total | PASS | FAIL | Notes |
|---|---|---|---|---|---|---|
| BLOCK=128 INT default (BOTH / FPGA / BRAM = engine T / TCVN2024) | Verilator 5.034, ASSERT=1 | 1 | 63 | 63 | 0 | row by row = v1.0.0 |
| BLOCK=128 EXT (engine T) | same | 1 | 63 | 55 | 8 | the 8 FAILs are the INT-only rows tb_001, 002, 003, 005, 104, 302, 506, 512, which do not apply to EXT by specification. Identical row by row to the v1.0.0 EXT baseline (diff empty); v1.0.0 excluded them from its EXT count. **55/55 applicable rows PASS** |
| BLOCK=256 suites (36 rows each) | same | 20 (ASIC A256 JDOM 6, ASIC A256 SEP 4, FPGA LOGIC A256 4, FPGA BRAM T256 6) | 720 | 720 | 0 | no assertion fired |
| Configuration matrix | same | 162 positive (152 legal + 10 extra: LUT alias, RS_LV=1, ignored-`DEC_ARCH` builds) | 3793 | 3793 | 0 | 0 build failures. BLOCK=128 part 1436/1436 over 64 builds (= v1.0.0); BLOCK=128 `DEC_ARCH="SEP"` build 33/33; BLOCK=256 part 2324/2324 over 97 builds |
| Illegal-parameter builds (must fail elaboration) | same | 11 | 11 | 11 rejected | 0 | the 8 v1.0.0 traps + `vb_mkv_illegal_param_BLOCK` (BLOCK=192) + `vb_mkv_illegal_param_DEC_ARCH` at BLOCK=128 and at 256 |
| BLOCK=256 coverage builds (incl. the 4 gap rows) | same, coverage-instrumented | 6 | 240 | 240 | 0 | verdicts recorded per build |

The Verilator co-simulation suite is the sign-off bench. No separate xsim testcase suite was run; xsim was used only
for the multi-cycle assertion (§ Assertions).

**Cross-checks**

| Check | Result |
|---|---|
| A256 ↔ T256 output data (tb_117 `[XENG256]`) | 97 builds, 12 (KEY_SCHED, DIR, PROFILE) groups, one digest each over A256 JDOM / SEP, T256 and every store: **0 differing** |
| SEP ↔ JDOM timing (tb_117 `[XTIM256]`) | 62 build groups: **0 differing** |
| SEP ↔ JDOM IP-port lockstep (random traffic, every output port every cycle) | **11/11 pairs PASS**, 1 000 000 cycles each, 0 mismatches. Negative control (byte reversal dropped in `vb_mkv_lin_m8i`, SEP side only): **2/2 detected** |
| BLOCK=128 cross-engine raw-key image (tb_110) | 12/12 groups identical |
| BLOCK=128 non-regression vs v1.0.0 | every engine A / T file, `key_ld`, `lin_slp`, `sbox_logic`, `cfg`, `seq_t`, `tbox_rom` and `rtl/lib/` byte-identical (scripted identity check PASS). **Port-trace equivalence: 66/66 builds** (60 legal + 2 LUT alias + 2 RS_LV=1 + 2 `DEC_ARCH="SEP"`) × 2 000 000 random cycles = 132 000 000 cycles, 0 mismatches except INFO[7:0] (0x03 → 0x04); 4 negative controls detected. The shell RTL (top / core / reg) has not changed since this proof |

**Timing contract.** It held exactly in every build: interval 2R, latency 2R+1, LAT {2R+1, 2R, R}.
- INT setup: engines A / A256 8R+4; engines T / T256 ENC 8R+6, DEC / BOTH-dec 8R+4⌊(R−1)/2⌋+((R−1) mod 2)+9. All
  ≤ 10R+12.
- EXT tail: engines A / A256 ≤ 2; engines T / T256 ENC 2, DEC 2R+3 / 2R+4. All ≤ 2R+4.

**Issues.** No issue was opened in the v1.1.0 cycle. The single historical issue (on testcase `tb_514`, classified as
an SVA bug, not an RTL bug) is resolved. No RTL bug is open.

Testcase categories exercised (from the testcase list), for both block sizes:
- Reset;
- Register/CSR (at BLOCK=256: the 5-bit map, MK0–MK15, address aliasing, INFO / LAT, RC bits, MK lock, EXT staging);
- Basic: published KATs (6 for MKV-256), KLEN × direction, cycle-exact timing, store white-box, every S / S⁻¹ value in
  every lane, mode switch, EXT order / rewrites, cross-engine digests;
- Edge;
- Back-pressure;
- Error inject: KLEN = 3, reject/request timing, EXT commit errors, missing commits;
- Stress: ≥ 10 000 random (key, block) pairs per KLEN × direction, soak ≥ 100 000 cycles;
- Interaction/Sequence: rekey while streaming, restarts (incl. at completion), resets mid-block / mid-setup, drain,
  KLEN / mode switches, random multi-step chains.

## Coverage

Measured with Verilator 5.034 (`verilator --coverage`, `verilator_coverage`) on the co-sim suite, over **10 builds**: T,
A, T256, A256 JDOM and A256 SEP, each with INT and EXT. Scope is DESIGN code (`rtl/*.v` + the used `rtl/lib/` files); bench and
SVA code are reported separately. The figures below are the **union** of the 10 builds, since each build instantiates
only its own engine and key source.

| Metric | Union of 10 builds | BLOCK=128 builds | BLOCK=256 builds | Target | Verdict |
|---|---|---|---|---|---|
| Line | 275 / 278 = **98.9 %** | 98.3 % | 98.4 % | ≥ 90 % | PASS |
| Toggle | 38087 / 39498 = **96.4 %** | 95.3 % | 96.7 % | ≥ 80 % | PASS |
| Functional (same-cycle SVA cover) | **75 / 75 = 100 %** | 48 / 48 | 49 / 49 | 100 % | PASS |
| Branch (information) | 180 / 184 = 97.8 % | 97.5 % | 97.6 % | — | info |
| Expression (information) | 374 / 408 = 91.7 % | 91.3 % | 90.6 % | — | info |

v1.0.0 reference (4 builds): 98.3 % / 94.3 % / 48 of 48.

**Coverage scope (carried from the coverage report; read before citing these numbers).**
- Coverage is evidence of what the suite exercised, not proof of correctness.
- Correctness is owned by the self-checking testcases (spec golden models), the SVA, and the regression and config
  matrix.
- Verilator measures line/block, toggle, branch and expression coverage, and functional coverage as SVA
  `cover property` points. There are 75 of them, all same-cycle; there are no multi-cycle temporal covers.
- **Not measured:** FSM state/transition coverage, SV `covergroup`s (none are used), multi-cycle temporal covers (none
  exist).
- Cover points are identified without the instance hierarchy (one module under different scopes counts once).
- Signals wider than 256 bits (the 512-bit `cfg_key` at BLOCK=256) are not toggle-instrumented by Verilator.
- The verdict authority for the full suite is the regression above. The six instrumented BLOCK=256 builds did record
  verdicts: 240/240 PASS.
- Stimulus is single-seed per testcase.

A customer who requires FSM, covergroup or temporal closure can re-run the same suite and SVA under a commercial
simulator.

Four BLOCK=256 rows were added to close coverage gaps (tb_023, tb_207, tb_312, tb_527 `_b256_`). They pass in the six
BLOCK=256 coverage builds, but they were added after the 173-entry matrix run (`errata.md` E21). Waivers: W1 (defensive
`default:` arms), W2 (parameter-constant branches) and W3 (`DCNT[31:11]` toggle). See `errata.md`.

## Assertions

From the SVA inventory, counted mechanically by script (re-run at the v1.1.0 sign-off: `TOTAL files=23
properties=294 covers=75 seq=1`): **294 SVA properties** in 23 observer files, with **75 `cover property` points**
(0 multi-cycle `SVA_COVER_SEQ`).
- BLOCK=128 / shell observers (14 files): 193 properties, 49 covers.
- BLOCK=256 engine observers (9 files): 101 properties, 26 covers.

The v1.0.0 report said 187 / 48. The difference comes from a recount under one mechanical rule (two hand counts were
low) plus one new v1.1.0 property (`ext_b256_staging_write`).

**The multi-cycle property.** `e2e_progress_bound` (`SVA_ASSERT_SEQ`, `vb_mkv_top_sva`) is compiled out under
Verilator, so the Verilator regression does not exercise it. It is checked on xsim (Vivado 2023.2) with all 23 observers
bound:
- v1.0.0 evidence on engines A and T;
- v1.1.0 evidence on four BLOCK=256 builds (A256 JDOM BOTH INT ASIC FF; A256 SEP BOTH EXT ASIC LATCH IETF2026; T256
  BOTH INT; T256 ENC EXT IETF2026). Each build runs the 6 MKV-256 KATs plus random setups with back-pressure and
  restarts: positive **PASS, 0 ASSERT** (426–429 blocks), and the negative control **FIRED**.

| Bind module | Properties | Covers | Categories |
|---|---:|---:|---|
| vb_mkv_top_sva | 10 | 4 | End-to-end, Integration |
| vb_mkv_reg_sva | 32 | 8 | Control invariant, Counter, EXT key load, Handshake/protocol, INT ties, Reset, Sticky status |
| vb_mkv_core_sva | 15 | 4 | Control invariant, Handshake/protocol, Integration, Latency/throughput, Reset |
| vb_mkv_cfg_sva | 23 | 5 | Control invariant, Environment contract, Handshake/protocol, Reset |
| vb_mkv_key_ld_sva | 17 | 4 | Data integrity, Handshake/protocol, Memory seam, Reset |
| vb_mkv_eng_a_sva | 10 | 2 | Assumption, Control invariant, Handshake/protocol, Latency/throughput, Memory seam, Reset |
| vb_mkv_seq_a_sva | 16 | 3 | Control invariant, Handshake/protocol, Memory seam, Reset, Sequencing |
| vb_mkv_kx_a_sva | 15 | 2 | Control invariant, Data integrity, Handshake/protocol, Latency/throughput, Memory seam, Reset |
| vb_mkv_round_a_sva | 6 | 5 | Data integrity |
| vb_mkv_eng_t_sva | 11 | 3 | Handshake/protocol, Latency/throughput, Reset |
| vb_mkv_kx_t_sva | 9 | 2 | Data integrity, Handshake/protocol, Latency/throughput, Memory seam |
| vb_mkv_seq_t_sva | 16 | 2 | Handshake/protocol, Reset, Sequencing |
| vb_mkv_round_t_sva | 10 | 3 | Data integrity, Memory seam, Sequencing |
| vb_mkv_tbox_rom_sva | 3 | 2 | Data integrity, Memory seam |
| vb_mkv_eng_a256_sva | 10 | 2 | Assumption, Control invariant, Handshake/protocol, Latency/throughput, Memory seam, Reset |
| vb_mkv_round_a256_sva (JDOM and SEP rounds) | 7 | 5 | Assumption, Control invariant, Data integrity |
| vb_mkv_kx_a256_sva | 15 | 2 | Control invariant, Data integrity, Handshake/protocol, Latency/throughput, Memory seam, Reset |
| vb_mkv_seq_a256_sva | 16 | 3 | Control invariant, Handshake/protocol, Memory seam, Reset, Sequencing |
| vb_mkv_key_ld256_sva | 17 | 4 | Data integrity, Handshake/protocol, Memory seam, Reset |
| vb_mkv_eng_t256_sva | 11 | 3 | Control invariant, Handshake/protocol, Latency/throughput, Memory seam, Reset |
| vb_mkv_round_t256_sva | 12 | 3 | Data integrity, Memory seam, Sequencing |
| vb_mkv_kx_t256_sva | 9 | 2 | Data integrity, Handshake/protocol, Latency/throughput, Memory seam |
| vb_mkv_tbox256_rom_sva | 4 | 2 | Data integrity, Memory seam, Sequencing |

Negative controls: the v1.0.0 harness fired 189/189 mutants. The BLOCK=256 observers were mutation-checked in the
engine benches (A256 20/20 with SVA; T256 30/30), and the BLOCK=256 shell mutants fired in the register-file unit
bench. The SVA self-check harness is development tooling and is not part of the deliverables (`errata.md` E16).

## Lint

The lint report concludes **Lint status: PASS**. The lint gate is Verilator + Vivado (project decisions of 2026-11-09
and 2026-11-11).

| Tool | Scope | Result |
|---|---|---|
| Verilator 5.034 `--lint-only -Wall` | 281 builds: default + 108 BLOCK=128 + 172 BLOCK=256 legal builds (all engines, all RKS_IMPL, JDOM and effective SEP) | 281/281: 0 errors, 0 warnings in the IP modules; 7 waived `GENUNNAMED` per build in the reused `rtl/lib/vb_sdp_ram_pp.v`; 0 inference-class warnings |
| Verilator legality traps | 12 illegal overrides | 12/12 rejected on the named `vb_mkv_illegal_param_*` module |
| Vivado v2023.2 `synth_design -lint` | 7 builds (engine T BOTH INT; engine A ASIC BOTH INT FF; T256 BOTH INT / EXT; A256 JDOM ASIC BOTH INT FF; A256 SEP ASIC BOTH EXT LATCH; A256 LOGIC FPGA BOTH INT) | 0 errors, 0 critical warnings; 3–41 advisory warnings per build, all classified; the latch / loop reports are the intentional ASIC latch cells of `rtl/lib/` (waived) |

The released copy of the RTL (`rtl/` of this repository) was also elaborated at the sign-off (Verilator
`--lint-only -Wall`, the default FPGA build at BLOCK=128 and BLOCK=256 through a minimal wrapper, plus `vb_mkv_top` A256
ASIC SEP LATCH): 0 errors, only the 7 known lib `GENUNNAMED` warnings.

## Static coherence

The feature trace (a static check that follows every IP-level feature through the submodules) PASSes. 38 features
(F01–F38) are traced through every engine, with 0 open `DROPPED_FEATURE` / `IFACE_MISMATCH` / `REG_CONFLICT`. The trace
raised four minor documentation findings (verdict PASS); all four were fixed in the design documentation before the
sign-off. The automated documentation drift check reports 0 drift over 29 modules and 21 registers.

## Open items

See `errata.md` for waived coverage gaps, unverified parameter combinations and documentation-level issues.
