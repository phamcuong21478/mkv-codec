# vb_mkv KAT waveform tests (Vivado xsim)

A small Vivado-simulator bench that runs the published MKV known-answer tests (KATs) through `vb_mkv_top` and
dumps the waveform, so you can see a key setup, an encryption burst and a decryption burst for each configuration.
It is a demonstration and smoke bench: the sign-off verification is the Verilator co-simulation suite described in
`doc/verification_report.md`, which is not published here.

## Requirements

- Vivado 2023.2 (`xvlog`, `xelab`, `xsim`). Other recent versions should work but were not tried.
- GNU make and bash.

Put the tools on `PATH` (`source <Vivado install>/settings64.sh`) or pass `XILINX_VIVADO=<Vivado install dir>` to
make.

## Usage

Run from `tb/`:

```sh
make list                          # configurations
make run CFG=t256_tcvn_ext         # compile, simulate, dump build/t256_tcvn_ext/wave.wdb
make run CFG=t256_tcvn_ext WAVE=vcd  # dump wave.vcd instead (WAVE=wdb|vcd|both|none)
make wave CFG=t256_tcvn_ext        # open the saved wave.wdb in the xsim GUI with the wave layout
make gui CFG=t256_tcvn_ext         # run live in the xsim GUI with the wave layout
make regress                       # all configurations, summary in build/regress.txt
make clean
```

`make run` prints the test log and fails (non-zero exit) unless the log ends in `[FINISH] PASS`. Every output of a
configuration is in `build/<cfg>/`: `sim.log`, `wave.wdb` / `wave.vcd`, and the compile and elaboration logs.

## Configurations

| CFG | Engine | BLOCK | DIR | TARGET / SBOX_IMPL | PROFILE | KEY_SCHED | RKS_IMPL | DEC_ARCH | RS_LV |
|---|---|---|---|---|---|---|---|---|---|
| `t128_tcvn_int` | T | 128 | BOTH | FPGA / BRAM | TCVN2024 | INT | FF | — | 0 |
| `t128_tcvn_ext` | T | 128 | BOTH | FPGA / BRAM | TCVN2024 | EXT | FF | — | 0 |
| `t128_ietf_int` | T | 128 | BOTH | FPGA / BRAM | IETF2026 | INT | FF | — | 0 |
| `t128_tcvn_int_enc` | T | 128 | ENC | FPGA / BRAM | TCVN2024 | INT | FF | — | 0 |
| `a128_tcvn_int_asic` | A | 128 | BOTH | ASIC / LOGIC | TCVN2024 | INT | FF | — | 0 |
| `a128_tcvn_ext_asic_latch` | A | 128 | BOTH | ASIC / LOGIC | TCVN2024 | EXT | LATCH | — | 0 |
| `a128_ietf_int_fpga_rs1` | A | 128 | BOTH | FPGA / LOGIC | IETF2026 | INT | FF | — | 1 |
| `t256_tcvn_int` | T256 | 256 | BOTH | FPGA / BRAM | TCVN2024 | INT | FF | — | 0 |
| `t256_tcvn_ext` | T256 | 256 | BOTH | FPGA / BRAM | TCVN2024 | EXT | FF | — | 0 |
| `t256_ietf_int` | T256 | 256 | BOTH | FPGA / BRAM | IETF2026 | INT | FF | — | 0 |
| `a256_tcvn_int_jdom` | A256 | 256 | BOTH | ASIC / LOGIC | TCVN2024 | INT | FF | JDOM | 0 |
| `a256_tcvn_ext_sep_latch` | A256 | 256 | BOTH | ASIC / LOGIC | TCVN2024 | EXT | LATCH | SEP | 0 |
| `a256_ietf_ext_jdom_macro` | A256 | 256 | BOTH | ASIC / LOGIC | IETF2026 | EXT | MACRO | JDOM | 0 |
| `a256_tcvn_int_jdom_dec` | A256 | 256 | DEC | ASIC / LOGIC | TCVN2024 | INT | FF | JDOM | 0 |

`RKS_IMPL="MACRO"` simulates the behavioural stand-in `rtl/lib/vb_sdp_ram_macro.v`, and the ASIC clock gates use the
behavioural `rtl/lib/vb_icg.v`. To add a configuration, add one line to the configuration table in the `Makefile` and
its name to `CFGS`.

## What one run does

For each published KAT that matches the build's BLOCK and PROFILE (three per configuration; two for IETF2026
MKV-128, which has no published 128-bit-key vector):

1. **Key setup for encryption.** INT: write the master-key words MK0… and CSR = `{KLEN, MODE=0}`. EXT: write CSR, wait
   for RKIDX.LDRDY, then commit the 2R+1 round keys through the staging words and RKIDX. Then poll CSR
   (OR-accumulating, since CFG_DONE / ERR are read-to-clear), check ERR = 0 and check LAT = {2R+1, 2R, R}.
2. **Encrypt burst.** Stream 4 copies of the plaintext back to back. Check every ciphertext, the latency (2R+1 cycles),
   the block interval (2R cycles) and DCNT = 4.
3. **Key setup and burst for decryption.** The same with MODE = 1, streaming the ciphertext and expecting the plaintext.

`DIR="ENC"` builds skip the decryption steps and `DIR="DEC"` builds skip the encryption steps. Before the first KAT the
bench checks INFO against the build parameters and CSR against its reset value.

The register sequences are the ones in `doc/programming_guide.md` (S1 for INT, S2 for EXT).

## Reading the waveform

`make wave` / `make gui` load `scripts/wave_view.tcl`, which groups the signals:

| Group | Signals |
|---|---|
| Test | `tb_phase` (ASCII: `READ_INFO`, `INT_KEY_ENC`, `EXT_KEY_DEC`, `WAIT_CFG_DONE`, `ENCRYPT`, `DECRYPT`, `DRAIN`, `DONE`), `tb_vec` (KAT number), `tb_blk` (block in the burst), `tb_mode`, `tb_expect` (expected output), `cyc`, `n_err` |
| Clock / reset | `clk`, `rst_n` |
| UPI register bus | `upi_we`, `upi_oe`, `upi_addr`, `upi_din`, `upi_dout` |
| Input stream | `din_valid`, `din_ready`, `din_data` |
| Output stream | `dout_valid`, `dout_ready`, `dout_data` |
| Core status | `dut/core2reg_cfg_busy` (key setup running), `dut/reg2core_cfg_vld` (setup start pulse) |

The `.wdb` holds every signal of the hierarchy, so you can add internal signals in the GUI. The `.vcd` opens in
viewers such as GTKWave.

## Files

| File | Purpose |
|---|---|
| `Makefile` | configuration table and the run / gui / wave / regress targets |
| `tb_mkv_kat.sv` | the testbench (SystemVerilog, xsim) |
| `mkv_kat_vectors.vh` | the KATs and their EXT round-key images, **generated** |
| `scripts/xsim_run.tcl` | batch run with waveform dump |
| `scripts/wave_view.tcl`, `scripts/gui_run.tcl` | GUI wave layout |

`mkv_kat_vectors.vh` holds the 11 published test vectors (TCVN 2024 draft and IETF 2026 draft) and, for each one, the
2R+1 round keys of the key schedule in the EXT index order (K_r^0 → 2r, K_r^1 → 2r+1, K_post → 2R). It was produced
from the MKV reference model, which checked every vector by encryption and decryption before it was written. The
model and the generator script stay in the development repository; the file is shipped as data and should not be
edited by hand.
