# vb_mkv Programming Guide — v1.1.0

This guide is for the firmware/software engineer who drives `vb_mkv` over its CPU bus. It gives the **ordered
register sequences** for each supported operating scenario. `register_reference.md` (the static map) and
`integration_guide.md` (the hardware hook-up) do not cover that. You do not need the design documentation to program
the IP.

> **Every sequence here is a verified flow.** Each scenario cites the testcases that exercise the sequence and ended in
> `[FINISH] PASS` in the sign-off regression: BLOCK=128 rows (`tb_0xx`–`tb_5xx` without `_b256_`) and BLOCK=256 rows
> (`tb_*_b256_*`). The ids name rows of the project's Verilator co-simulation suite, which is not published in this
> repository (`verification_report.md`). The register values are the ones those testcases use. A
> scenario with no backing testcase is not documented here. It is listed under §5 and in `errata.md`.

Addresses are the IP's **native word addresses** on `s_upi_addr`. A byte-addressed host bus sees them at 4 × the word
address (CSR 0x00, DCNT 0x04, INFO 0x08, LAT 0x0C, MK0 0x10 … MK7 0x2C, RKIDX 0x30; at BLOCK=256 also MK8 0x40 … MK15
0x5C) through the integrator's bridge.

## 1. Programming model

- **Bus:**
  - native UPI, address width 4 bits (BLOCK=128) or 5 bits (BLOCK=256) (word address), data width 32;
  - one access per strobe, read data 1 cycle later;
  - full map in `register_reference.md`.
- **Block-size differences software must know** (identify the build from INFO[14], §3.10):

  | Item | BLOCK=128 | BLOCK=256 |
  |---|---|---|
  | KLEN 0 / 1 / 2 | 128 / 192 / 256-bit key | 256 / 384 / 512-bit key |
  | INT key words | MK0–MK3 / 0–5 / 0–7 (0x04–0x0B) | MK0–MK7 / 0–11 / 0–15 (MK0–MK7 at 0x04–0x0B, MK8–MK15 at 0x10–0x17) |
  | EXT staging round key | MK0–MK3 (128 bits) | MK0–MK7 (256 bits) |
  | R for KLEN 0/1/2 | TCVN2024 6/7/8, IETF2026 7/8/9 | same |
  | INFO[7:0] / INFO[14] | 0x04 / 0 | 0x04 / 1 |

- **Control discipline:**
  - Configuration is held in CSR {KLEN, MODE} and the MK words (INT) or loaded through the staging words + RKIDX (EXT).
  - **Every CSR write starts (or restarts) a key setup** with the register values present at that write. There is no
    separate START bit.
  - Data then flows on the hardware streams. Software only observes the stream through DCNT.
- **Completion signalling:**
  - Poll CSR until CFG_DONE (bit 1) or ERR (bit 4) is set. **Both bits are read-to-clear.** Keep the OR of every CSR
    value read during the poll (§4).
  - EXT builds also expose RKIDX.LDRDY (bit 8, a level with no side effect) for the load window.
  - There is no interrupt line.
- **Ordering rules:**
  1. INT: write every MK word the key needs **before** the CSR write. From the cycle after the CSR write until the
     setup completes, the MK words are **locked**: a write is ignored and sets ERR.
  2. EXT: write CSR first, wait for LDRDY = 1, then for each index write the staging words and **then** RKIDX = index.
     The commit takes the staging value present at the RKIDX write.
  3. Do not write CSR merely to read-modify-write MODE: every CSR write is a new key setup.
  4. Stream data only after CFG_DONE = 1 with ERR = 0. Until then the IP holds `din_ready` = 0, so data is never lost,
     but it waits.

### 1.1 Registers that must be initialised before first use

| Register | Reset value | Why it must be written | Verified by |
|---|---|---|---|
| MK0…MK(k/32−1) (INT; up to MK15 at BLOCK=256) | 0x0000_0000 | the all-zero reset key is a valid key: skipping the MK writes silently encrypts with the zero key | 128: `tb_100_basic_kat`, `tb_101_basic_klen_dir`; 256: `tb_111_b256_basic_kat`, `tb_112_b256_basic_klen_dir` |
| CSR {KLEN, MODE} | 0x0000_0000 (0x0000_0001 for DIR=DEC) | nothing is processed until a CSR write completes a key setup (`din_ready` = 0 after reset); KLEN, and MODE in BOTH builds, select the operation | 128: `tb_008_reset_state`, `tb_100_basic_kat`; 256: `tb_014_b256_reg_reset_all`, `tb_111_b256_basic_kat` |
| Round keys 0…2R via the staging words + RKIDX (EXT) | store not initialised | the setup completes only when every index 0…2R has been committed; a wrong value gives a wrong result, not an error | 128: `tb_108_basic_ext_kat`, `tb_305_err_ext_incomplete`; 256: `tb_111_b256_basic_kat` (EXT), `tb_311_b256_err_ext_incomplete` |

## 2. Operating scenarios

| # | Scenario | Purpose | Key config | Verified by (BLOCK=128) | Verified by (BLOCK=256) |
|---|---|---|---|---|---|
| S1 | INT key load + encrypt / decrypt | normal operation with the on-chip key schedule | `KEY_SCHED="INT"` | `tb_100_basic_kat`, `tb_101_basic_klen_dir`, `tb_smoke_loopback` | `tb_111_b256_basic_kat`, `tb_112_b256_basic_klen_dir` |
| S2 | EXT round-key load + encrypt / decrypt | software-computed key schedule | `KEY_SCHED="EXT"` | `tb_108_basic_ext_kat`, `tb_012_reg_ext_map`, `tb_110_basic_v4_raw_image_xeng` | `tb_111_b256_basic_kat`, `tb_019_b256_reg_ext_map`, `tb_117_b256_basic_xeng_digest` |
| S3 | EXT load in any order / with rewrites | driver freedom in commit order | EXT | `tb_109_basic_ext_order` | `tb_116_b256_basic_ext_order` |
| S4 | Mode switch (BOTH) with the same key | alternate encrypt / decrypt | `DIR="BOTH"` | `tb_102_basic_mode_both`, `tb_503_seq_mode_switch` | `tb_115_b256_basic_mode_both`, `tb_525_b256_seq_klen_mode_switch` |
| S5 | Rekey / KLEN switch while streaming | change key between bursts | any | `tb_500_seq_rekey_streaming`, `tb_504_seq_klen_switch`, `tb_517_seq_ext_rekey_streaming` (EXT) | `tb_519_b256_seq_rekey_streaming`, `tb_525_b256_seq_klen_mode_switch` |
| S6 | Restart a running setup | software changes its mind mid-setup | any | `tb_506_seq_csr_restart`, `tb_507_seq_restart_storm`, `tb_518_seq_restart_at_completion`, `tb_516_seq_ext_restart_midload` (EXT) | `tb_520_b256_seq_csr_restart`, `tb_523_b256_seq_ext_restart_midload`, `tb_527_b256_seq_restart_at_completion` |
| S7 | INT MK lock (MK write during setup) | error behaviour of an early MK write | INT | `tb_013_reg_mk_lock`, `tb_505_seq_mk_during_setup` | `tb_018_b256_reg_mk_lock` |
| S8 | Invalid key length (KLEN = 3) | error handling, key invalidation | any | `tb_300_err_klen3`, `tb_006_reg_err_rc`, `tb_302_err_reject_then_request`, `tb_307_err_reject_then_request_exact`, `tb_304_err_ext_klen3` (EXT) | `tb_308_b256_err_klen3`, `tb_022_b256_reg_rc_dcnt`, `tb_312_b256_err_reject_then_request_exact` |
| S9 | EXT commit errors | rejected / dropped / missing commits | EXT | `tb_303_err_ext_commit`, `tb_306_err_ext_dropped_commit`, `tb_305_err_ext_incomplete` | `tb_309_b256_err_ext_commit`, `tb_310_b256_err_ext_dropped_commit`, `tb_311_b256_err_ext_incomplete` |
| S10 | Block counter / status read-back | throughput accounting, discovery | any | `tb_007_reg_dcnt`, `tb_004_reg_info_lat`, `tb_000_reg_reset_all` | `tb_022_b256_reg_rc_dcnt`, `tb_023_b256_reg_dcnt_same_cycle`, `tb_017_b256_reg_info_lat`, `tb_014_b256_reg_reset_all` |
| S11 | Recovery after reset | re-initialise after `rst_n` | any | `tb_508_seq_reset_idle`, `tb_509_seq_reset_mid_block`, `tb_510_seq_reset_mid_setup`, `tb_009_reset_values_after_use` | `tb_020_b256_reset_after_use`, `tb_521_b256_seq_reset_mid_block`, `tb_522_b256_seq_reset_mid_setup` |

## 3. Programming sequences

`poll X until C (timeout T)` = read X repeatedly, OR every value read into an accumulator, and stop when the
accumulator meets C. If T elapses, treat it as a hardware fault. The timeouts below are the bounds the verified suite
used:
- BLOCK=128 rows: 500 CSR reads for an INT setup, 600 for EXT completion, 2000 RKIDX reads for LDRDY;
- BLOCK=256 rows: 2000 CSR reads for setup / completion, 4000 RKIDX reads for LDRDY.

The hardware bounds are ≤ 10R+12 cycles for an INT setup plus up to one in-flight block (≤ 2R), and ≤ 2R+4 cycles after
the last EXT commit, for both block sizes.

### 3.1 S1 — INT key load + encrypt / decrypt  —  verified by `tb_100_basic_kat`, `tb_101_basic_klen_dir`, `tb_111_b256_basic_kat`, `tb_112_b256_basic_klen_dir`

Use this flow for every key change in INT builds. Example values: published vector #1, TCVN2024, KLEN = 0.

| Step | Op | Register.Field | Value (BLOCK=128, from `tb_100`) | Value (BLOCK=256, from `tb_111_b256`) | Wait / condition |
|---|---|---|---|---|---|
| 1 | write | MK0 (0x04) | 0x0102_0304 (key bytes 0–3) | 0x0102_0304 | — |
| 2 | write | MK1 (0x05) | 0x0506_0708 | 0x0506_0708 | — |
| 3 | write | MK2 (0x06) | 0x090A_0B0C | 0x090A_0B0C | — |
| 4 | write | MK3 (0x07) | 0x0D0E_0F11 | 0x0D0E_0F11 | BLOCK=128: 192-bit keys also write MK4–MK5, 256-bit MK4–MK7 |
| 5 | write | MK4–MK7 (0x08–0x0B) | — | 0x1213_1415, 0x1617_1819, 0x1A1B_1C1D, 0x1E1F_2223 | BLOCK=256: 384-bit keys also write MK8–MK11 (0x10–0x13), 512-bit MK8–MK15 (0x10–0x17) |
| 6 | write | CSR (0x00) {KLEN[3:2], MODE[0]} | `(KLEN << 2) \| MODE`: 0x0 = KLEN 0 / enc, 0x1 = KLEN 0 / dec, 0x4 = KLEN 1 / enc, 0x8 = KLEN 2 / enc, 0x9 = KLEN 2 / dec | same encoding | starts the key setup; the MK words are now locked until it completes |
| 7 | poll | CSR.CFG_DONE \| CSR.ERR | bit 1 or bit 4 set | same | the read clears both bits; keep the OR (timeouts above) |
| 8 | check | accumulated CSR.ERR | 0 | 0 | ERR = 1 → §4 |
| 9 | stream | `din_*` / `dout_*` | plaintext `112233445566778899AABBCCDDEEFF00` → `B331228334C3F81A37206591498756A1` | plaintext `112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00` → `CF2F2C1008186A578FE5B45DBD154473940C2BEC5682CDF83A3564A72DB0161B` | hardware handshake; the decrypt direction returns the plaintext |
| 10 | read (optional) | DCNT (0x01) | number of accepted blocks | same | the read clears DCNT |

MODE is honoured only for `DIR="BOTH"`. ENC builds force 0, DEC builds force 1, and writing the "wrong" MODE is not an
error (`tb_002_reg_csr_fields`, `tb_115_b256_basic_mode_both`).

### 3.2 S2 — EXT round-key load  —  verified by `tb_108_basic_ext_kat`, `tb_012_reg_ext_map`, `tb_111_b256_basic_kat`, `tb_019_b256_reg_ext_map`

Software computes the 2R+1 round keys with the spec key schedule: K_r^0 → index 2r, K_r^1 → index 2r+1, K_post → index
2R. Each key is BLOCK bits wide and is written as the staging words with MK0 = first key bytes: {MK0..MK3} at BLOCK=128,
{MK0..MK7} at BLOCK=256. R follows from KLEN and PROFILE (6/7/8 TCVN2024, 7/8/9 IETF2026), so the indices are 0…12 /
0…14 / 0…16 (TCVN2024). The same image works on every engine of one block size (BLOCK=128: `tb_110_basic_v4_raw_image_xeng`;
BLOCK=256 A256 and T256: `tb_117_b256_basic_xeng_digest`).

| Step | Op | Register.Field | Value | Wait / condition |
|---|---|---|---|---|
| 1 | write | CSR (0x00) | `(KLEN << 2) \| MODE` | opens a new load window (any previous key is invalidated) |
| 2 | poll | RKIDX.LDRDY (0x0C bit 8) | 1 | level, no side effect (timeouts above) |
| 3 | write | staging: MK0..MK3 (0x04–0x07) at BLOCK=128; MK0..MK7 (0x04–0x0B) at BLOCK=256 | K_i words | never locked in EXT. At BLOCK=256, MK8–MK15 are not part of the staging key (writes ignored) |
| 4 | write | RKIDX (0x0C) [4:0] | i | commits store[i] ← staging |
| 5 | repeat | steps 3–4 | for i = 0 … 2R | — |
| 6 | poll | CSR.CFG_DONE \| CSR.ERR | bit 1 or bit 4 set | keep the OR |
| 7 | check | accumulated CSR.ERR | 0 | ERR = 1 → §4 / S9 |
| 8 | read (optional) | LAT (0x03) | {8'd0, 2R+1, 2R, 4'd0, R}, e.g. 0x000D_0C06 for R = 6 | LDRDY reads 0 after completion |
| 9 | stream | `din_*` / `dout_*` | — | — |

### 3.3 S3 — EXT load in any order / with rewrites  —  verified by `tb_109_basic_ext_order`, `tb_116_b256_basic_ext_order`

Steps 3–4 of S2 may visit the indices in **any** order (reverse or permuted), and an index may be committed more than
once: the last value wins. The load completes on the commit that first covers every index 0…2R. CFG_DONE is never
set while an index is missing (`tb_305_err_ext_incomplete`, `tb_311_b256_err_ext_incomplete`: LDRDY stays 1 and
`din_ready` stays 0).

### 3.4 S4 — Mode switch with the same key (`DIR="BOTH"`)  —  verified by `tb_102_basic_mode_both`, `tb_503_seq_mode_switch`, `tb_115_b256_basic_mode_both`, `tb_525_b256_seq_klen_mode_switch`

| Step | Op | Register.Field | Value | Wait / condition |
|---|---|---|---|---|
| 1 | write | CSR (0x00) | same KLEN, MODE = 1 (decrypt) or 0 (encrypt) | INT: the MK registers still hold the key, so no MK writes are needed. EXT: reload the round keys (S2 steps 2–7) |
| 2 | poll | CSR.CFG_DONE \| CSR.ERR | set | timeouts above |
| 3 | stream | — | — | blocks transferred before step 1 finish in the old mode |

### 3.5 S5 — Rekey / KLEN switch while streaming  —  verified by `tb_500_seq_rekey_streaming`, `tb_504_seq_klen_switch`, `tb_517_seq_ext_rekey_streaming`, `tb_519_b256_seq_rekey_streaming`, `tb_525_b256_seq_klen_mode_switch`

INT: wait for CFG_DONE of the current key (the MK words are locked during a setup), then run S1 with the new key and
KLEN while data keeps flowing. EXT: run S2. Blocks transferred up to the CSR-write cycle are processed with the old key
and delivered in order. `din_ready` stays 0 from the next cycle until the new setup completes, and every later block
uses the new key. LAT follows the new KLEN.

### 3.6 S6 — Restart a running setup  —  verified by `tb_506_seq_csr_restart`, `tb_507_seq_restart_storm`, `tb_518_seq_restart_at_completion`, `tb_516_seq_ext_restart_midload`, `tb_520_b256_seq_csr_restart`, `tb_523_b256_seq_ext_restart_midload`, `tb_527_b256_seq_restart_at_completion`

A CSR write at any time during a pending or running setup restarts it with the current CSR value. There is exactly one
completion, for the **last** write. A CSR write landing in the completion cycle is also honoured (`tb_518`, `tb_527_b256`).
- INT: the MK words are locked during the setup, so the restart uses the MK content of the first CSR write. To restart
  with a different key, wait for CFG_DONE, write MK, then write CSR. An MK write attempted inside the window sets ERR
  (S7).
- EXT: the restart clears the commit-coverage mask, so all 2R′+1 indices of the new KLEN must be committed again.

### 3.7 S7 — INT MK lock  —  verified by `tb_013_reg_mk_lock`, `tb_505_seq_mk_during_setup`, `tb_018_b256_reg_mk_lock`

An MK write (MK0–MK7; at BLOCK=256 also MK8–MK15) from the cycle after a CSR write (`cfg_vld`) up to and including the
last busy cycle is **ignored**: the read-back keeps the old value and CSR.ERR is set. The setup uses the MK content at
the CSR write. The first write after the setup completes is accepted with no ERR. CSR writes are never locked. EXT
builds have no lock. Recovery: read CSR (clears ERR), then write MK and CSR again.

### 3.8 S8 — Invalid key length (KLEN = 3)  —  verified by `tb_300_err_klen3`, `tb_006_reg_err_rc`, `tb_302_err_reject_then_request`, `tb_307_err_reject_then_request_exact`, `tb_304_err_ext_klen3`, `tb_308_b256_err_klen3`, `tb_022_b256_reg_rc_dcnt`, `tb_312_b256_err_reject_then_request_exact`

| Step | Op | Register.Field | Value | Wait / condition |
|---|---|---|---|---|
| 1 | write | CSR (0x00) | KLEN = 3 (e.g. 0x0000_000C) | — |
| 2 | poll | CSR | CFG_DONE and ERR | both set on the same edge |
| 3 | — | — | — | no key is loaded; the previous key is **invalidated**; LAT reads 0; `din_ready` stays 0; EXT: no load window (LDRDY 0) and later commits set ERR |
| 4 | recover | S1 / S2 | valid KLEN | a held input block is then processed with the new key |

A valid CSR write landing right after the reject (even in the reject cycle) is honoured: ERR is set first, and
CFG_DONE follows when the new setup completes (`tb_307`, `tb_312_b256`). Hence the OR-accumulating poll.

### 3.9 S9 — EXT commit errors  —  verified by `tb_303_err_ext_commit`, `tb_306_err_ext_dropped_commit`, `tb_309_b256_err_ext_commit`, `tb_310_b256_err_ext_dropped_commit`

The following RKIDX writes set ERR and **do not** write the store:
- a commit while the window is closed (LDRDY = 0); the old key stays active;
- IDX > 2R (e.g. 2R+1, 31); the window stays open and the load can still complete;
- a commit in the cycle right after a CSR write (the window is being restarted);
- a commit one cycle after the completing commit (dropped; the stored image is unchanged).

At BLOCK=256, writes to MK8–MK15 around a commit are not committed (`tb_309_b256`). To stay clear, commit only while
LDRDY = 1 and stop committing once all indices are written.

### 3.10 S10 — Counter and status read-back  —  verified by `tb_007_reg_dcnt`, `tb_004_reg_info_lat`, `tb_000_reg_reset_all`, `tb_022_b256_reg_rc_dcnt`, `tb_023_b256_reg_dcnt_same_cycle`, `tb_017_b256_reg_info_lat`, `tb_014_b256_reg_reset_all`

- DCNT (0x01) returns the number of accepted input blocks (128- or 256-bit) since the last DCNT read and restarts
  counting. A block accepted in the read cycle counts toward the next read (`tb_023_b256`).
- INFO (0x02) identifies the build (version 0x04, DIR, SBOX_IMPL, PROFILE, TARGET, KEY_SCHED, BLOCK) and has no side
  effect. Use it to select the driver path (INT vs EXT, block size, R table). `DEC_ARCH` is not visible to software.
- LAT (0x03) gives R, 2R and 2R+1 for the loaded key, or 0 when no key is loaded.

### 3.11 S11 — Recovery after reset  —  verified by `tb_508_seq_reset_idle`, `tb_509_seq_reset_mid_block`, `tb_510_seq_reset_mid_setup`, `tb_009_reset_values_after_use`, `tb_020_b256_reset_after_use`, `tb_521_b256_seq_reset_mid_block`, `tb_522_b256_seq_reset_mid_setup`

After `rst_n` (at idle, mid-block or mid-setup):
- every register returns to its reset value (all MK words = 0, CSR = 0 / DEC 1, DCNT = 0, LAT = 0);
- in-flight blocks are discarded and `din_ready` stays 0;
- re-run S1 or S2 from step 1.

## 4. Status, completion and interrupt handling

- **Status registers:**
  - CSR.CFG_DONE (bit 1, RC) sets when a setup completes and also after a rejected request (together with ERR).
  - CSR.ERR (bit 4, RC) sets on a KLEN = 3 reject, an INT MK write while locked, or a rejected or dropped EXT commit.
  - RKIDX.LDRDY (bit 8, level) is set while the EXT load window is open.
- **Polling pattern:**

  ```c
  uint32_t acc = 0;
  for (n = 0; n < TIMEOUT; n++) {
      acc |= rd(CSR);
      if (acc & (CFG_DONE | ERR)) break;
  }
  ```

  - On timeout: fault.
  - If `acc & ERR`: the request was rejected, or an earlier MK / RKIDX access was refused. Re-read the sequence, then
    redo S1 / S2.
  - Otherwise the key is loaded.
- **No interrupt line:** completion is detected by polling the status register above.

> **Read-to-clear hazard.** CFG_DONE and ERR are read-to-clear. Every CSR read clears both, so a CSR read for any
> other purpose (for example to check MODE) consumes a pending completion or error. The set has priority over a
> same-cycle read-clear, so no event is lost in hardware. Software loses the event if it reads CSR and discards the
> value. Always accumulate (OR) the CSR values you read and act on them. The ERR of a refused MK/RKIDX write may arrive
> before the CFG_DONE of the setup it accompanies. DCNT is also read-to-clear: read it from one owner only.
> Where a level is available (RKIDX.LDRDY), poll the level.

## 5. Unverified scenarios

- **Depth of verification per build.**
  - BLOCK=128: the full 63-row suite (every scenario above) runs on the two default builds (FPGA BRAM, engine T, INT and
    EXT). The other legal builds run the 36-row config-matrix subset, which contains at least one cited row per
    scenario. These rows are **not** in the BLOCK=128 matrix and were therefore verified only on the engine-T default
    builds: tb_102, tb_504, tb_505, tb_506, tb_507, tb_006, tb_302, tb_007, tb_512 (register traffic while streaming),
    the random chains tb_513–515 and the long back-pressure / stress rows tb_201–203, tb_403, tb_404. This is unchanged
    from v1.0.0.
  - BLOCK=256: the 36-row suite runs on 20 representative builds (A256 ASIC JDOM / SEP, A256 FPGA LOGIC, T256). Every
    legal BLOCK=256 build runs the matrix list. ASIC LATCH / MACRO store builds run only the unfiltered rows (reset /
    INFO / KAT / cycle-exact / store image / EXT order / cross-engine digest / S-box lanes / EXT commit rows). The
    random-stress rows run only on DIR=BOTH, FF-store, RS_LV=0 builds.
  - The four BLOCK=256 rows `tb_023_b256`, `tb_207_b256`, `tb_312_b256` and `tb_527_b256` (cited above for S6, S8,
    S10) passed in the six BLOCK=256 coverage builds (240/240) but were added after the 173-entry matrix run, so they
    have not yet run across all builds (`errata.md` E21).
- **Real bus bridge.** Programming through a real (non-bench) bus bridge is not verified. The suite drove UPI through a
  bench-only AXI4-Lite adapter.
- **Netlist.** No gate-level (post-synthesis / post-route netlist) simulation of any sequence was run.

Cross-reference: `errata.md` § Unverified configurations.
