# vb_mkv — MKV-128 / MKV-256 Block Cipher IP, v1.1.0

- **IP:** vb_mkv (MKV-128 / MKV-256 block cipher accelerator, top module `vb_mkv_top`)
- **Version:** 1.1.0 (additive release over 1.0.0)
- **Status:** **RELEASE**. All release gates are met (`doc/errata.md` § Release gate).
- **License:** MIT, Copyright (c) 2026 Cuong T.Pham (`LICENSE.txt`)
- **Target:** Verilog-2005 RTL soft-IP, single clock domain. The **product target is ASIC** (engines A / A256). The
  Kintex-7 FPGA build (`xc7k160tfbg676-3`) is the proof-of-concept / demo target.
- **Release date:** 2026-11-11
- **RTL:** `rtl/` is the RTL that was verified and signed off for v1.1.0. The only difference is one header comment
  line in `rtl/lib/vb_sdp_ram_pp.v`, where a personal email address was removed (`doc/errata.md` E28).

`vb_mkv` encrypts and decrypts with MKV, the block cipher of the 2024 draft Vietnamese national standard (TCVN) [R1],
in ECB, using a 2-cycle round. The block size is set at compile time:
- **`BLOCK=128`** (default): MKV-128, 128-bit blocks, 128/192/256-bit keys. It is cycle-identical to v1.0.0; the only
  visible change is the INFO version byte, which reads 0x04 instead of 0x03.
- **`BLOCK=256`** (new in 1.1.0): MKV-256, 256-bit blocks, 256/384/512-bit keys.

Both block sizes accept a new block every 2R cycles and deliver it after exactly 2R+1 cycles. The round profile is
TCVN2024 or IETF2026. A CPU configures the IP over a 16-word register bus (32 words at `BLOCK=256`); the data moves
over valid/ready streams. The IP is meant for SoC or FPGA designers who need an ECB block-cipher engine behind a CPU.

## Repository layout

```
.
├── README.md                    this file
├── LICENSE.txt                  MIT License
├── doc/
│   ├── datasheet.md             product brief
│   ├── integration_guide.md     hardware integration
│   ├── programming_guide.md     software / firmware register sequences
│   ├── register_reference.md    register map
│   ├── verification_report.md   verification sign-off
│   └── errata.md                release gates, known issues, limitations
├── rtl/
│   ├── vb_mkv_*.v               28 IP modules (top: vb_mkv_top.v)
│   └── lib/                     vb_sdp_ram_pp.v, vb_icg.v, vb_sdp_ram_macro.v
└── tb/                          KAT waveform tests for Vivado xsim (see tb/README.md)
```

## Documentation

| Document | What it covers |
|----------|----------------|
| `doc/datasheet.md` | Features, configuration, interfaces, per-build performance (FPGA and ASIC proxy), power, verification summary |
| `doc/integration_guide.md` | Files to compile, instantiation, parameters, clock/reset, bus and stream protocols, ASIC hooks, FPGA constraints and the timing sign-off recipe |
| `doc/programming_guide.md` | Per-scenario register sequences for software/firmware, each traced to the verified testcases |
| `doc/register_reference.md` | Register map for both block sizes (addresses, fields, access, reset values) |
| `doc/verification_report.md` | Verification sign-off: tests, configuration matrix, cross-checks, coverage, assertions, lint |
| `doc/errata.md` | Release-gate status, known issues (including errata to v1.0.0), coverage waivers, unverified configurations |

## Quick start

1. Add every file under `rtl/` and `rtl/lib/` to your project. The top module is `vb_mkv_top`.
2. Instantiate it from the template in `doc/integration_guide.md` §2 and choose the parameters (§3).
3. Bring the IP up with the checklist in `doc/integration_guide.md` §7 (INFO read-back and test vector #1).
4. Program it with the register sequences in `doc/programming_guide.md`.
5. FPGA: apply the constraints and the implementation recipe in `doc/integration_guide.md` §10–§11. The rated
   frequencies depend on that recipe.

ASIC integrators also map the clock-gate cell and, for `RKS_IMPL="MACRO"`, provide the RF macro wrapper
(`doc/integration_guide.md` §9).

To see the IP work, run the KAT waveform tests in Vivado xsim. In `tb/`, run `make run CFG=t128_tcvn_int` and then
`make wave CFG=t128_tcvn_int`; `make list` shows the 14 configurations (`tb/README.md`).

## What this repository does not contain

This repository publishes the synthesizable RTL, the integration documentation and a small KAT waveform bench for
Vivado xsim (`tb/`). The following stay in the development repository; the documents quote their results:
- the verification environment: the Verilator + C++ co-simulation bench with its 103 self-checking testcases (63 for
  BLOCK=128, 40 for BLOCK=256), the golden models and the bound SVA observers. Testcase names such as
  `tb_100_basic_kat` in the documents identify rows of that suite;
- the synthesis and implementation scripts and their reports;
- the full design document, the per-module documents and the raw coverage, lint and assertion reports;
- the MKV reference model and the script that generated `tb/mkv_kat_vectors.vh`.

The `tb/` bench shows the published test vectors on 14 configurations. It is a demonstration and smoke bench, not the
sign-off suite. There is no example wrapper and no Vivado IP-catalog packaging script.

## At a glance

- **Performance (FPGA, PoC, `xc7k160tfbg676-3`, post-route, setup and hold clean):**
  - `BLOCK=128`, engine T (default build): **rated 296 MHz** for INT and EXT, with the pblock + ExtraTimingOpt recipe
    (`doc/integration_guide.md` §11). Full IP: INT 1616 LUT + 86 LUTRAM / 1238 FF / 8 RAMB36, EXT 1426 / 86 / 1059 / 8.
  - `BLOCK=256`, engine T256 (FPGA default at 256): **rated 225 MHz** for INT and EXT, with ExtraTimingOpt. Full IP: INT
    3552 LUT + 172 LUTRAM / 2297 FF / 32 RAMB36, EXT 2705 / 172 / 2000 / 32. Core ring 1.80–2.57× the published MKV-256
    Kintex-7 baseline ([R1] Table 23) at 225 MHz, and 2.11–2.74× in the best runs.
  - Power (vectorless, post-route): BLOCK=256 T256 at 225 MHz 0.39 W INT / 0.41 W EXT; BLOCK=128 default build 0.229 W
    (post-synth).
- **Performance (ASIC proxy, product target; yosys + Nangate45 typical, not sign-off):**
  - engine A (BLOCK=128): 23.1–35.4 kGE, 209–359 Mbps/kGE;
  - engine A256 (BLOCK=256, JDOM): 49.4–72.4 kGE, 178–303 Mbps/kGE. JDOM is 6.2–8.4 kGE smaller than SEP in every
    DEC/BOTH INT build.
- **Verification:**
  - BLOCK=128: INT 63/63; EXT 55/55 applicable rows (the 8 INT-only rows fail by specification, as in v1.0.0);
  - BLOCK=256: 20 builds × 36 rows, 720/720;
  - config matrix: 173 entries, 3793 PASS / 0 FAIL, 11/11 illegal builds rejected;
  - BLOCK=128 port trace against v1.0.0: 66 builds × 2 000 000 cycles, 0 mismatches except INFO[7:0];
  - coverage over the union of 10 builds: line 98.9 %, toggle 96.4 %, functional 75/75 SVA covers;
  - 294 SVA properties; lint PASS (Verilator 281 builds + Vivado 7 builds).
- **Known issues:** errata E1–E28. E14 is a v1.0.0 item that is already closed; it keeps its number so the ids stay
  stable. No release gate is open. See `doc/errata.md`.

## References

- **[R1]** Ban Cơ yếu Chính phủ (Government Cipher Committee of Vietnam), *Thuyết minh dự thảo Tiêu chuẩn Việt Nam:
  Công nghệ thông tin – Các kỹ thuật an toàn – Các thuật toán mật mã – Mã khối MKV* (explanatory note to the draft TCVN
  "Information technology – Security techniques – Cryptographic algorithms – MKV block cipher"), Hà Nội, 2024.
  <https://datafiles.chinhphu.vn/cpp/files/duthaovbpl/2024/thuyet-minh-du-thao-tcvn-thuat-toan.pdf>
  - §3.2: MKV overview, 128-bit blocks with 128/192/256-bit keys and 256-bit blocks with 256/384/512-bit keys.
  - §3.7.2: published Kintex-7 (`xc7k160tfbg676-3`) implementation results. Tables 21–22 (MKV-128) and Table 23
    (MKV-256) are the baselines used in `doc/datasheet.md`.
