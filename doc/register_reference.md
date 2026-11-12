# vb_mkv Register Reference — v1.1.0

This is the CPU-bus register map of `vb_mkv`. The bus is native UPI (`s_upi_*` on `vb_mkv_top`) with 32-bit data.
Addresses are **word** addresses: 4 bits at `BLOCK=128` and 5 bits at `BLOCK=256`. A byte-addressed bridge sees
register `n` at byte offset `4·n`. The BLOCK=128 map is the v1.0.0 map; the only difference is INFO[7:0] = 0x04.

> **Source.** This map is rendered from the register chapters of the project's design documentation. An automated
> drift check compares those chapters with the RTL register decode (`rtl/vb_mkv_reg.v`: 21 addresses incl. MK8–MK15,
> writability, read-clear, reset 0); it reported **0 mismatches** at the v1.1.0 sign-off. The register header of the
> verification bench was not used as a source.

## Access types

| Code | Meaning |
|---|---|
| RO | Read-only |
| RW | Read/write |
| RC | Read-to-clear (reading the register clears it) |
| RSVD | Reserved: reads 0, writes ignored |

There are no W1C bits.

> **RC hazard.** CSR.CFG_DONE, CSR.ERR and the whole of DCNT are read-to-clear one-shot events. In hardware a set
> has priority over a same-cycle read-clear, so no event is lost there. Software loses the event if it reads the
> register and discards the value. **Poll CSR by OR-accumulating every value read**, and give each RC register a
> single software owner. Where a level exists (RKIDX.LDRDY), poll the level.

## Register map

| Offset (word) | Byte offset | Name | Access | Reset | BLOCK=128 | BLOCK=256 |
|---|---|---|---|---|---|---|
| 0x00 | 0x00 | CSR | RW / RC | 0x0000_0000 (0x0000_0001 for DIR=DEC) | mode, key length, sticky status. **Any write starts a key setup** | same |
| 0x01 | 0x04 | DCNT | RC | 0x0000_0000 | accepted 128-bit input blocks since the last read | accepted 256-bit input blocks |
| 0x02 | 0x08 | INFO | RO | build-dependent | version and build options (default build 0x0000_0604) | same, INFO[14] = 1 (default build 0x0000_4604) |
| 0x03 | 0x0C | LAT | RO | 0x0000_0000 | cycle figures of the loaded key | same |
| 0x04–0x0B | 0x10–0x2C | MK0–MK7 | RW | 0x0000_0000 | INT: master key words 0–7. EXT: MK0–MK3 round-key staging, MK4–MK7 reserved | INT: master key words 0–7. EXT: **MK0–MK7 = 256-bit round-key staging** (all writable) |
| 0x0C | 0x30 | RKIDX | EXT: RW / RO · INT: RSVD | 0x0000_0000 | EXT round-key commit index + load-window level | same (commits the 256-bit staging) |
| 0x0D–0x0F | 0x34–0x3C | — | RSVD | 0x0000_0000 | reserved | reserved |
| 0x10–0x17 | 0x40–0x5C | MK8–MK15 | RW | 0x0000_0000 | not addressable (4-bit address) | INT: master key words 8–15, locked during setup. EXT: reserved (read 0, writes ignored) |
| 0x18–0x1F | 0x60–0x7C | — | RSVD | 0x0000_0000 | not addressable | reserved |

## Bit fields

### CSR — `0x00` (RW / RC)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 0 | MODE | RW (DIR=BOTH) / RO | 0 (DIR=DEC: 1) | 0 = encrypt, 1 = decrypt. ENC/DEC builds force the value; writing another value is **not** an error |
| 1 | CFG_DONE | RC | 0 | set when a key setup completes (the `cfg_busy` fall), also after a rejected request (with ERR). **Cleared by any CSR read**; set wins over a same-cycle read |
| 3:2 | KLEN | RW | 0 | BLOCK=128: 0 = 128-bit, 1 = 192-bit, 2 = 256-bit key. BLOCK=256: 0 = 256-bit, 1 = 384-bit, 2 = 512-bit key. 3 = invalid (rejected: ERR, key invalidated) |
| 4 | ERR | RC | 0 | set by: a KLEN = 3 request; (INT) an MK write while a setup is pending or running; (EXT) a rejected RKIDX commit (window closed, IDX > 2R, commit in the cycle after a CSR write) or a dropped commit. **Cleared by any CSR read**; set wins |
| 31:5 | — | RSVD | 0 | read 0, writes ignored |

Writing CSR (any value) produces one key-setup request in the next cycle. A write during a pending or running setup
restarts it. Safe usage: write CSR exactly once per intended setup, then OR-accumulate CSR reads until CFG_DONE or
ERR.

### DCNT — `0x01` (RC)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 31:0 | DCNT | RC | 0 | number of input blocks accepted (`din_valid && din_ready`) since the last DCNT read. The read returns the count and restarts at 0, or at 1 if a block is accepted in the read cycle |

### INFO — `0x02` (RO)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 7:0 | VERSION | RO | **0x04** | register/timing contract version, the same for every build (v1.0.0: 0x03). It identifies the contract, not the release version (1.1.0) |
| 9:8 | DIR | RO | param | 0 = ENC, 1 = DEC, 2 = BOTH |
| 10 | SBOX_IMPL | RO | param | 1 = BRAM (engine T / T256), 0 = LOGIC or the `"LUT"` alias (engine A / A256) |
| 11 | PROFILE | RO | param | 0 = TCVN2024, 1 = IETF2026 |
| 12 | TARGET | RO | param | 0 = FPGA, 1 = ASIC |
| 13 | KEY_SCHED | RO | param | 0 = INT, 1 = EXT |
| 14 | BLOCK | RO | param | 0 = 128, 1 = 256 (new in v1.1.0; 0 in every BLOCK=128 build) |
| 31:15 | — | RSVD | 0 | read 0. `DEC_ARCH` and `RKS_IMPL` are not reported |

INFO[10] = 1 with INFO[14] = 1 identifies engine T256. INFO[12] = 0, INFO[10] = 0 and INFO[14] = 1 identify engine A256
on LUTs.

### LAT — `0x03` (RO)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 3:0 | R | RO | 0 | rounds of the loaded key (6/7/8 TCVN2024, 7/8/9 IETF2026, for both block sizes); 0 = no key |
| 7:4 | — | RSVD | 0 | — |
| 15:8 | CPB | RO | 0 | cycles per block in streaming = 2R |
| 23:16 | LATENCY | RO | 0 | input transfer → `dout_valid` = 2R+1 |
| 31:24 | — | RSVD | 0 | — |

All LAT fields are 0 while no key is loaded. They clear on every new request and on a reject, and are loaded when the
setup completes. Example after a KLEN = 0 key with TCVN2024 (R = 6): `0x000D_0C06` for both block sizes.

### MK0–MK7 — `0x04`–`0x0B` (RW)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 31:0 | MKn | RW | 0 | **INT:** master-key word n. MK0 holds the first four key bytes (key byte 0 in [31:24]). BLOCK=128: 128-bit keys use MK0–MK3, 192-bit MK0–MK5, 256-bit MK0–MK7. BLOCK=256: 256-bit keys use MK0–MK7 (384-bit and 512-bit keys continue in MK8–MK15). **Locked** from the cycle after a CSR write until the setup completes: a write is ignored and sets ERR. **EXT, BLOCK=128:** MK0–MK3 = 128-bit staging round key {MK0..MK3} (never locked); MK4–MK7 reserved (read 0, writes ignored). **EXT, BLOCK=256:** MK0–MK7 = 256-bit staging round key {MK0..MK7} (never locked) |

### MK8–MK15 — `0x10`–`0x17` (RW, BLOCK=256 only)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 31:0 | MKn | RW | 0 | **INT:** master-key words 8–15 (384-bit keys use MK0–MK11, 512-bit MK0–MK15), locked like MK0–MK7. **EXT:** reserved (read 0, writes ignored; never part of a commit). Not addressable at BLOCK=128 |

Unused key words are still stored, readable and (INT) locked.

### RKIDX — `0x0C` (EXT: RW / RO; INT: RSVD)

| Bits | Field | Access | Reset | Description |
|---|---|---|---|---|
| 4:0 | IDX | RW | 0 | a write commits store[IDX] ← staging ({MK0..MK3} at BLOCK=128, {MK0..MK7} at BLOCK=256). It is accepted iff LDRDY = 1, the previous cycle was not a CSR write, and IDX ≤ 2R of the current KLEN; otherwise ERR is set and nothing is stored. Reads return the last written IDX; no read side effect |
| 7:5 | — | RSVD | 0 | — |
| 8 | LDRDY | RO (level) | 0 | 1 while the EXT load window is open (from shortly after a valid CSR write until the completing commit) |
| 31:9 | — | RSVD | 0 | — |

Index map of the software key image: K_r^0 → 2r, K_r^1 → 2r+1 (r = 0…R−1), K_post → 2R. It is identical for every
engine of one block size. In INT builds address 0x0C is reserved: a write is ignored with no ERR, and a read returns 0.
