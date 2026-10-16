# Debugging rv_dm in CHERIoT mode on Verilator

This walks through running `rv_dm_cheriot_caps` in the Verilator chip simulation and driving the debug module by hand, either through OpenOCD's telnet port or through GDB. It reads capabilities out of the core with 64-bit Access Register commands, before and after the core switches from RV32I to CHERIoT.

## How the test works

The device image is [`sw/device/tests/rv_dm_cheriot_caps.S`](sw/device/tests/rv_dm_cheriot_caps.S). It stops twice and waits for you. At each stop it prints a marker and then spins until register `a5` is non-zero. You halt the hart, do your checks, write `a5 = 1`, and resume.

| Stop | Console marker | Core mode | What you check |
|---|---|---|---|
| 1 | `RV32 READY` | RV32I | 64-bit register reads are rejected, 32-bit ones work |
| 2 | `CHERIOT READY` | CHERIoT | 64-bit reads return the whole capability (address and metadata) |

Before stop 2 the image prints the capabilities it holds, so you know what to expect:

```
CAP s0 10000000 7e002000
CAP a0 3000065e 5e00dc5e
CAP a1 00000000 7e3e0000
CAP mtdc 00000000 7e3e0000
```

Each line is `CAP <register> <address> <metadata>`. The values above are from a real run. `a0` points into the flash image, so its address changes whenever the image is rebuilt. Always compare against the lines your own run prints.

| Register | What it holds |
|---|---|
| `s0` | A 16-byte data capability on a scratch buffer at the start of main SRAM |
| `a0` | A capability derived from the program counter, so it has execute rather than store permission |
| `a1` | A copy of the memory root (`mtdc`) |
| `mtdc` | The memory root itself, read through the Special Capability Register path |

After you release stop 2, the image checks that `s0`, `a0` and `a1` still carry their tags and are bit-identical to copies it kept. `s0` and `a0` are the registers the debug module borrows while it runs, so this checks that it saves and restores them as full capabilities.

The run ends with one of these console lines:

| Line | Meaning |
|---|---|
| `CHERIOT DEBUG PASS` | Everything survived the halt |
| `FAIL E` | `CHERIOT_ENA` did not read back as written, before the switch |
| `FAIL M` | The core did not come out of the switch in CHERIoT mode |
| `FAIL S` / `FAIL A` / `FAIL B` | `s0` / `a0` / `a1` lost its tag or changed across the halt |
| `RTRAP <mcause>` / `CTRAP <mcause>` | The core trapped, in RV32 or CHERIoT mode respectively |

## Setup

You need four terminals, all in the repo root.

| Terminal | Runs |
|---|---|
| 1 | The Verilator simulation, which also shows the device console |
| 2 | OpenOCD |
| 3 | A telnet session to OpenOCD, for raw debug-module commands |
| 4 | GDB, or a plain shell for capturing traces |

Use either telnet (terminal 3) or GDB (terminal 4) to drive the hart, not both at once. They talk to the same OpenOCD, and OpenOCD reacts to halts that GDB requests. The telnet route is the most direct and is described first.

### Terminal 1: simulation

The Verilator build needs Verilator 4.210. Version 5 rejects the `#` delays in the AST models with `%Error-NEEDTIMINGOPT`.

```sh
export PATH=/nix/store/0s2bcp5xyp1cikmd23dpvhk5hv04jidg-verilator-4.210/bin:$PATH
verilator --version          # must say 4.210
bazel run --test_output=streamed //sw/device/tests:rv_dm_cheriot_caps_sim_verilator
```

If Bazel still reports Verilator 5 in its tool check, run `bazel shutdown` and try again.

Expect, in order:

1. Build output, then `Simulation of OpenTitan Earl Grey`.
2. A line `$ kill -USR1 <pid>`. Note the PID, you need it for traces.
3. `JTAG: Virtual JTAG interface dmi0 is listening on port 44853`. OpenOCD can connect from here on.
4. After a few minutes: `Test ROM complete, jumping to NVM`, then `RV32 READY`.

### Terminal 2: OpenOCD

Start this once terminal 1 shows the `listening on port 44853` line.

```sh
bazel run //third_party/openocd -- -s util/openocd -f board/lowrisc-earlgrey-verilator.cfg
```

Expect:

```
Info : JTAG tap: riscv.tap tap/device found: 0x04f5484d ...
Warn : JTAG tap: riscv.tap       UNEXPECTED: 0x04f5484d ...
Error: JTAG tap: riscv.tap  expected 1 of 1: 0x10021cdf ...
Error: Trying to use configured scan chain anyway...
Info : datacount=2 progbufsize=8
Info :  hart 0: XLEN=32, misa=0x40101106
Info : Listening on port 3333 for gdb connections
```

The IDCODE "error" is harmless. The simulation's debug port reports a different ID from the board configuration, and OpenOCD carries on. `XLEN=32` and a `misa` with bit 8 (`I`) set are expected while the core is still in RV32 mode.

### Terminal 3: telnet

```sh
telnet localhost 4444
```

The first attempt on `::1` may be refused, it then connects on `127.0.0.1`. You get a `>` prompt. Run this once, straight away:

```
poll off
```

This stops OpenOCD from issuing its own debug-module commands when it notices a halt, so the only commands are the ones you type.

### Terminal 4: GDB (optional)

Only needed for the GDB route below. Otherwise keep it as a plain shell for traces.

```sh
bazel run @lowrisc_rv32imcb_toolchain//:bin/riscv32-unknown-elf-gdb -- -ex "set remotetimeout 120" -ex "target extended-remote :3333"
```

`set remotetimeout 120` matters. The simulated JTAG link is slow, and GDB's default two-second timeout shows up as `Ignoring packet error, continuing...`.

## Test sequence (telnet)

Run these in terminal 3. Wait for each expected value before moving on. Lines starting with `#` are explanations, do not type them.

**The one rule that matters:** after every `riscv dmi_write 0x17 ...`, repeat `riscv dmi_read 0x16` until bit 12 (`0x1000`) is clear, waiting a few seconds between reads. The simulation is slow, so the first read is often still busy (`0x8001002`). While the debug module is busy, reads of `data0`/`data1` return junk and any access to `data0`, `data1` or `command` is ignored and sets the sticky "busy" error (cmderr 1). If you see `0x8001102` or `0x8000102`, you touched one of them too early: wait for busy to clear, clear the error with `riscv dmi_write 0x16 0x700`, and repeat the step.

### Stop 1: RV32 mode

Wait for `RV32 READY` in terminal 1.

```
# Halt the hart
riscv dmi_write 0x10 0x80000001
riscv dmi_read 0x11
```

Repeat `riscv dmi_read 0x11` until the value contains `0x300` (halted), for example `0x382` or `0x30382`. The simulation is slow, so the first read often still shows running (`0xc82` or `0x30c82`).

```
# Drop the halt request
riscv dmi_write 0x10 0x1

# 64-bit read of a1: must be rejected in RV32 mode
riscv dmi_write 0x17 0x32100b
riscv dmi_read 0x16
```

Expect `0x8000202`: cmderr 2, "not supported".

```
# Clear the error
riscv dmi_write 0x16 0x700

# 32-bit read of a5: must work, and a5 is 0 while the image waits
riscv dmi_write 0x17 0x22100f
riscv dmi_read 0x16
riscv dmi_read 0x4
```

Expect `0x8000002` (done, no error) once busy clears, then `0x0`.

```
# Release the image: a5 = 1, then resume
riscv dmi_write 0x4 1
riscv dmi_write 0x17 0x23100f
riscv dmi_read 0x16
riscv dmi_write 0x10 0x40000001
```

Expect `0x8000002` after the write. After the resume, terminal 1 prints the four `CAP` lines and `CHERIOT READY`.

### Stop 2: CHERIoT mode

Wait for `CHERIOT READY` in terminal 1. Write down the four `CAP` lines.

```
# Clear anything left over, then halt
riscv dmi_write 0x16 0x700
riscv dmi_write 0x10 0x80000001
riscv dmi_read 0x11
```

Repeat `riscv dmi_read 0x11` until it contains `0x300`, as before.

```
riscv dmi_write 0x10 0x1
```

Now read each capability. For each one, issue the command, check `abstractcs`, then read the two halves.

```
# s0 as a capability
riscv dmi_write 0x17 0x321008
riscv dmi_read 0x16
riscv dmi_read 0x4
riscv dmi_read 0x5
```

Expect `0x8000002`, then the address and metadata from the `CAP s0` line (for example `0x10000000` and `0x7e002000`).

Repeat with these command words, comparing against the matching `CAP` line:

| Register | Command | `data0` (`0x4`) | `data1` (`0x5`) |
|---|---|---|---|
| `a0` | `riscv dmi_write 0x17 0x32100a` | `CAP a0` address | `CAP a0` metadata |
| `a1` | `riscv dmi_write 0x17 0x32100b` | `CAP a1` address | `CAP a1` metadata |
| `mtdc` | `riscv dmi_write 0x17 0x32001d` | `CAP mtdc` address | `CAP mtdc` metadata |

Optional extra checks, each followed by `riscv dmi_read 0x16`:

```
# 32-bit read of s0: only the address half, in data0
riscv dmi_write 0x17 0x221008

# dcsr and dpc: ordinary 32-bit CSR reads, should complete
riscv dmi_write 0x17 0x2207b0
riscv dmi_write 0x17 0x2207b1

# x16 does not exist in CHERIoT mode (RV32E): expect cmderr 3, 0x8000302
riscv dmi_write 0x17 0x221010
riscv dmi_write 0x16 0x700
```

Optional round trip through `a2`. This writes `a1`'s bits into `a2` and reads them back. The tag is not carried, which is a known limitation, but the bits should match.

```
riscv dmi_write 0x4 <a1 address>
riscv dmi_write 0x5 <a1 metadata>
riscv dmi_write 0x17 0x33100c
riscv dmi_read 0x16
riscv dmi_write 0x17 0x32100c
riscv dmi_read 0x16
riscv dmi_read 0x4
riscv dmi_read 0x5
```

Release the image:

```
riscv dmi_write 0x4 1
riscv dmi_write 0x17 0x23100f
riscv dmi_read 0x16
riscv dmi_write 0x10 0x40000001
```

Terminal 1 should print `CHERIOT DEBUG PASS` and the run ends.

## Test sequence (GDB)

The same protocol, driven from GDB in terminal 4 instead of telnet. Do not type `poll off` in telnet for this route. `monitor <command>` passes any OpenOCD command through, so all the `riscv dmi_*` commands above work from GDB too.

1. Start GDB once terminal 1 shows `RV32 READY`. OpenOCD halts the hart when GDB connects.
2. At stop 1:
   ```
   (gdb) monitor riscv dmi_write 0x17 0x32100b
   (gdb) monitor riscv dmi_read 0x16
   (gdb) monitor riscv dmi_write 0x16 0x700
   (gdb) set $a5 = 1
   (gdb) continue
   ```
   Expect `0x8000202` from the read.
3. When terminal 1 shows `CHERIOT READY`, press Ctrl-C in GDB to halt.
4. At stop 2, use the `monitor riscv dmi_*` commands from the telnet section to read the capabilities. `info registers s0 a0 a1` shows only the address halves, since GDB knows nothing about capabilities.
5. `set $a5 = 1`, then `continue`.

GDB asks for all 32 integer registers when the hart halts, but in CHERIoT mode the core only has x0 to x15. Expect the reads of x16 to x31 to fail and to make halting slow. If that gets in the way, use the telnet route.

## Capturing a trace

The simulation writes an FST trace while tracing is toggled on. If the hart gets stuck, a few seconds of trace shows where. Run this in a free shell (terminal 4 if you are not using GDB):

```sh
kill -USR1 <pid>; sleep 10; kill -USR1 <pid>
```

`<pid>` is from the `kill -USR1` line in terminal 1. The trace is `sim.fst` in the simulation's working directory, the `CWD:` path at the top of terminal 1 (it ends in `rv_dm_cheriot_caps_sim_verilator.bash.runfiles/_main`). `uart0.log` with the console output is in the same directory.

Convert it with `fst2vcd -f sim.fst -o sim.vcd`, or open it with `gtkwave sim.fst`. Useful signals, all under `TOP.chip_sim_tb.u_dut.top_earlgrey.earlgrey_pd_main`:

| Signal | Shows |
|---|---|
| `u_rv_core_ibex.u_core.u_ibex_core.pc_id` | The instruction being decoded. The debug module's memory is at `0x10000`, the park loop at `0x10800` |
| `u_rv_core_ibex.u_core.u_ibex_core.instr_rdata_id` | The instruction word |
| `u_rv_core_ibex.u_core.u_ibex_core.debug_mode` | 1 while the hart is in debug mode |
| `u_rv_core_ibex.u_core.u_ibex_core.data_addr_o`, `data_req_o`, `data_we_o`, `data_err_i` | Loads and stores, and whether they get a bus error |
| `u_rv_core_ibex.u_core.u_ibex_core.id_stage_i.controller_i.ctrl_fsm_cs` | Core controller state. 5 is decode, 6 is flush (an exception or similar) |
| `u_rv_dm.u_dm_top.i_dm_mem.state_q` | Debug module command state. 0 Idle, 1 Go, 2 Resume, 3 CmdExecuting |
| `u_rv_dm.u_dm_top.i_dm_mem.cheriot_en` | Which park loop and encodings the debug module presents |

Use [`hw/vendor/pulp_riscv_dbg/debug_rom/debug_rom_cheriot.dump`](hw/vendor/pulp_riscv_dbg/debug_rom/debug_rom_cheriot.dump) to map park-loop PCs to instructions (subtract `0x10000`).

## Cheatsheet

### OpenOCD commands

| Command | Does |
|---|---|
| `poll off` | Stop OpenOCD polling the hart and reacting to halts on its own |
| `poll on` | Turn it back on |
| `riscv dmi_read <addr>` | Read a debug-module register directly |
| `riscv dmi_write <addr> <value>` | Write a debug-module register directly |
| `halt`, `resume` | OpenOCD's own halt and resume. These also read registers, so avoid them in CHERIoT mode while debugging the debug module |
| `reg` | OpenOCD's register view (32-bit only) |

### Debug-module registers

| DMI address | Register | Use |
|---|---|---|
| `0x04` | `data0` | Low half of a transfer. For a capability, the address |
| `0x05` | `data1` | High half of a 64-bit transfer. For a capability, the metadata |
| `0x10` | `dmcontrol` | Halt, resume, reset requests |
| `0x11` | `dmstatus` | Is the hart halted or running |
| `0x16` | `abstractcs` | Did the last abstract command finish, and did it fail |
| `0x17` | `command` | Writing here starts an abstract command |
| `0x20` | `progbuf0` | First program-buffer word |

### `dmcontrol` values (`0x10`)

| Value | Effect |
|---|---|
| `0x80000001` | Request a halt (keeps the debug module active) |
| `0x40000001` | Request a resume |
| `0x00000001` | Clear any request, keep the debug module active |
| `0x10000001` | Acknowledge "have reset" |
| `0x00000000` | Deactivate the debug module. Writing `0x1` afterwards resets its state, which can unstick a wedged `busy` |

Always keep bit 0 (`dmactive`) set unless you mean to reset the debug module.

### Reading `dmstatus` (`0x11`)

| Bit | Mask | Meaning |
|---|---|---|
| 8, 9 | `0x300` | Hart halted |
| 10, 11 | `0xc00` | Hart running |
| 12, 13 | `0x3000` | Hart unavailable |
| 16, 17 | `0x30000` | Resume acknowledged (stays set after a resume) |
| 18, 19 | `0xc0000` | Hart has been reset since the last acknowledge |

Low bits `0x82` are always there (authenticated, debug spec 0.13). Typical values: `0x30382` halted, `0x30c82` running.

### Reading `abstractcs` (`0x16`)

The value is `0x080X_Y002` in this design: progbufsize 8, datacount 2, with the interesting bits in the middle.

| Value | Meaning | What to do |
|---|---|---|
| `0x8000002` | Done, no error | Read `data0`/`data1` |
| `0x8001002` | Busy (bit 12): the command is still running | Read again. If it stays busy, the hart is not completing the command. Capture a trace |
| `0x8000102` | cmderr 1, busy: `data0`, `data1` or `command` was accessed while a command was running, and that access was ignored | Wait for busy to clear, clear with `0x700`, repeat the ignored step |
| `0x8001102` | Still busy, and cmderr 1 is already set | Keep polling until bit 12 clears, then as above |
| `0x8000202` | cmderr 2, not supported | Expected for 64-bit accesses in RV32 mode |
| `0x8000302` | cmderr 3, exception: the hart faulted running the command | Expected for registers that do not exist (x16 to x31 in CHERIoT mode) |
| `0x8000402` | cmderr 4, halt/resume: the hart was not halted | Halt first, check `dmstatus` |

Errors are sticky. Clear them with `riscv dmi_write 0x16 0x700` before the next command, or every later command also fails.

### Building a `command` value (`0x17`)

For an Access Register command:

```
command = (aarsize << 20) | (1 << 17) | (write << 16) | regno
```

| Field | Values |
|---|---|
| `aarsize` | 2 for 32 bits, 3 for 64 bits (a whole capability, accepted only in CHERIoT mode) |
| bit 17, `transfer` | Always set here |
| `write` | 0 to read the register into `data0`/`data1`, 1 to write it from them |
| `regno` | `0x1000 + n` for GPR `xn`. A CSR number for 32-bit accesses. A Special Capability Register index for 64-bit accesses below `0x1000` |

Ready-made values:

| Command | Operation |
|---|---|
| `0x321008` | 64-bit read of `s0` (x8) |
| `0x32100a` | 64-bit read of `a0` (x10) |
| `0x32100b` | 64-bit read of `a1` (x11) |
| `0x32100c` | 64-bit read of `a2` (x12) |
| `0x33100c` | 64-bit write of `a2` |
| `0x32001d` | 64-bit read of `mtdc` (Special Capability Register 29) |
| `0x221008` | 32-bit read of `s0` |
| `0x22100f` | 32-bit read of `a5` (x15) |
| `0x23100f` | 32-bit write of `a5` (releases the image when `data0` is 1) |
| `0x2207b0` | 32-bit read of the CSR `dcsr` |
| `0x2207b1` | 32-bit read of the CSR `dpc` |
| `0x221010` | 32-bit read of x16, which does not exist in CHERIoT mode |

Other Special Capability Registers for 64-bit reads: `0x320018` `depcc`, `0x32001c` `mtcc`, `0x32001e` `mscratchc`, `0x32001f` `mepcc`.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `%Error-NEEDTIMINGOPT` while building the simulation | Verilator 5 on `PATH` | Put Verilator 4.210 first on `PATH`, `bazel shutdown`, rebuild |
| OpenOCD cannot connect | Started before the simulation was listening | Wait for `listening on port 44853` in terminal 1, restart OpenOCD |
| `dmstatus` never shows halted | The simulation is slow | Keep polling, it can take a few reads |
| `data0`/`data1` read back junk (for example `0x4000`) | Read while the command was still busy | Poll `0x16` until busy clears, then read them |
| `abstractcs` stays `0x8001002` for more than about 30 seconds | The hart is not completing the command | Capture a trace. Check `pc_id` and `state_q`. With `state_q = 1` (Go), the hart has not picked up the command |
| cmderr 4 (`0x8000402`) | The command was sent while the hart was running | Halt and confirm with `dmstatus` first |
| All commands fail after one error | cmderr is sticky | `riscv dmi_write 0x16 0x700` |
| GDB: `Ignoring packet error, continuing...` | GDB timed out waiting for OpenOCD | Start GDB with `set remotetimeout 120`. If OpenOCD shows `Timed out ... waiting for busy to go low`, see the busy row above |
| OpenOCD: `Failed to read memory (addr=0x0)` | GDB probing address 0 for a stack frame | Harmless |
| Terminal 1 prints `CTRAP` or `RTRAP` | The core trapped. The number is `mcause` | `0x2` illegal instruction, `0x1c` CHERI fault, `0x5`/`0x7` load/store access fault |
| `FAIL S`, `FAIL A` or `FAIL B` at the end | A register came back without its tag or with different bits | Compare the 64-bit reads with the `CAP` lines. If they matched, the corruption happened on the way back (park loop or resume) |
| The debug module is wedged with `busy` set | Typically after a hang | Restart the simulation. Toggling `dmactive` (`0x10` to `0x0` then `0x1`) resets the debug module, but not the hart |

## Background

The bug this guide was written to find: the CHERIoT park loop had been built for the old debug-module memory layout (`GOING` at `0x104`, exception entry at `0x808`), while the vendored debug module uses the new one (`GOING` at `0x108`, exception entry at `0x810`). The "going" store got a bus error and the hart looped forever in the park loop. It is fixed in `debug_rom_cheriot.S` and the regenerated `debug_rom_cheriot.sv`. If `busy` sticks again, the trace section above is the quickest way to see why.
