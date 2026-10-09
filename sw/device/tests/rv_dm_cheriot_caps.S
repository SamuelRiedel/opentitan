// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Device side of the rv_dm CHERIoT capability test.
 *
 * The host harness, `//sw/host/tests/chip/rv_dm:cheriot_caps`, drives the
 * debug module over JTAG while this image runs. The two meet at two
 * rendezvous points, each of which is a console marker followed by a spin on
 * `a5`. The host halts the hart, does its checks, releases the spin by writing
 * a non-zero value into `a5` with an abstract command, and resumes.
 *
 *   1. `RV32 READY`: still in RV32 mode. The host checks that 64-bit Access
 *      Register commands are rejected.
 *   2. `CHERIOT READY`: in CHERIoT mode, with known capabilities in `s0`, `a0`
 *      and `a1`. Before the marker, each one is printed as
 *
 *        CAP <name> <address> <metadata>
 *
 *      in hex, so that the host can compare what it reads with 64-bit Access
 *      Register commands against what the core holds without having to know
 *      the capability encoding. `mtdc` is printed too, for the Special
 *      Capability Register path.
 *
 * After the second release the image checks that `s0`, `a0` and `a1` survived
 * the halt with their tags and every bit intact. `s0` and `a0` are the two
 * registers the debug module itself borrows, spilling them to
 * `dscratch0`/`dscratch1`, so this is what catches a debug ROM or an abstract
 * command that saves them as integers rather than as capabilities.
 *
 * Ends with `CHERIOT DEBUG PASS` or `FAIL <letter>`. The letter names the
 * check that failed:
 *
 *   E    `CHERIOT_ENA` did not read back as written
 *   M    the core did not come out of the switch in CHERIoT mode
 *   S    `s0` lost its tag or changed across the halt
 *   A    `a0` lost its tag or changed across the halt
 *   B    `a1` lost its tag or changed across the halt
 *
 * The chip-level UVM test `chip_sw_rv_dm_cheriot_caps` drives the same
 * protocol without a console. It waits for the PC to reach
 * `rv_dm_cheriot_caps_wait_rv32` or `rv_dm_cheriot_caps_wait_cheriot`, takes
 * the expected capabilities from `rv_dm_cheriot_caps_expected` rather than
 * from the `CAP` lines, and gets the result from the DV test status window,
 * which this image only writes when built with `DV_TEST_STATUS`.
 *
 * As in `cheriot_smoketest.S`, everything up to the mode switch executes as
 * RV32 despite being assembled for CHERIoT, so that part sticks to encodings
 * that are the same in both modes.
 *
 * Register use:
 *
 *   s0, a0, a1   capabilities under test, owned by the host while halted
 *   a2           written by the host in a round-trip check; scratch otherwise
 *   a5           rendezvous flag, written by the host
 *   gp, tp, t0   copies of s0, a0, a1 for the post-halt check
 *   s1           UART0, an integer address before the switch and a
 *                capability after it
 *   a3, a4, t1   console scratch
 *   t2           scratch, and `mtdc` while it is reported
 *
 * `rv_dm_cheriot_caps_expected` holds the four capabilities in the order
 * `s0`, `a0`, `a1`, `mtdc`, eight bytes each, in the in-memory format: address
 * in the lower word, metadata in the upper. That is exactly what a 64-bit
 * abstract command returns in `data0` and `data1`.
 */

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_memory.h" // Generated.
#include "hw/top/uart_regs.h"  // Generated.

// MISA.E reads as set only while CHERIoT mode is active, and MISA.I is driven
// as its complement.
#define MISA_E (1 << 4)
#define MISA_I (1 << 8)
#define MISA_MODE (MISA_E | MISA_I)

// Test status values for the DV window. A pass is only accepted directly from
// `IN_TEST`.
#define DV_STATUS_IN_TEST 0x4354
#define DV_STATUS_PASSED 0x900d
#define DV_STATUS_FAILED 0xbaad

// Offsets of the capabilities in `rv_dm_cheriot_caps_expected`.
#define EXP_S0 0
#define EXP_A0 8
#define EXP_A1 16
#define EXP_MTDC 24
#define EXP_SIZE 32

// -----------------------------------------------------------------------------
// Console helpers. These only use `s1` as the base, so the stores encode the
// same in both modes.

/** Write the character `ch` to UART0, waiting for space in the FIFO. */
.macro putc ch
1:
  lw   a4, UART_STATUS_REG_OFFSET(s1)
  andi a4, a4, (1 << UART_STATUS_TXFULL_BIT)
  bnez a4, 1b
  addi a3, x0, \ch
  sw   a3, UART_WDATA_REG_OFFSET(s1)
.endm

/** Write `a2` to UART0 as eight hex digits, most significant first. */
.macro puthex
  addi t1, x0, 8
1:
  srli a3, a2, 28
  slli a2, a2, 4
  addi a4, x0, 10
  blt  a3, a4, 2f
  addi a3, a3, ('a' - 10 - '0')
2:
  addi a3, a3, '0'
3:
  lw   a4, UART_STATUS_REG_OFFSET(s1)
  andi a4, a4, (1 << UART_STATUS_TXFULL_BIT)
  bnez a4, 3b
  sw   a3, UART_WDATA_REG_OFFSET(s1)
  addi t1, t1, -1
  bnez t1, 1b
.endm

/** Write the character held in register `reg` to UART0. */
.macro putr reg
1:
  lw   a4, UART_STATUS_REG_OFFSET(s1)
  andi a4, a4, (1 << UART_STATUS_TXFULL_BIT)
  bnez a4, 1b
  sw   \reg, UART_WDATA_REG_OFFSET(s1)
.endm

.macro put_crlf
  putc '\r'
  putc '\n'
.endm

/**
 * Record capability register `creg` at offset `slot` of
 * `rv_dm_cheriot_caps_expected`, and finish a `CAP <name> <address> <metadata>`
 * line for it. The caller prints `CAP <name>` first.
 *
 * The metadata half is read back from memory: storing the capability through
 * `cs0` and loading the upper word gives exactly the bits a 64-bit abstract
 * command should return in `data1`, with no need to decode them here.
 */
.macro putcap creg, slot
  csc  \creg, \slot(s0)
  putc ' '
  cgetaddr a2, \creg
  puthex
  putc ' '
  lw   a2, (\slot + 4)(s0)
  puthex
  put_crlf
.endm

.macro putcap_prefix
  putc 'C'
  putc 'A'
  putc 'P'
  putc ' '
.endm

/**
 * Spin until the host writes a non-zero value into `a5`. `label` is a global
 * symbol on the spin, so that a testbench can wait for the PC to reach it.
 */
.macro wait_for_host label
  addi a5, x0, 0
  .globl \label
\label:
  beqz a5, \label
.endm

/**
 * Write `val` to the DV test status window. Works in both modes: the window is
 * reached through an integer address in RV32 mode and through a capability
 * derived from the memory root in CHERIoT mode. Uses `t1` and `t2`. Expands to
 * nothing unless built with `DV_TEST_STATUS`.
 */
.macro dv_status val
#ifdef DV_TEST_STATUS
  csrr t2, misa
  andi t2, t2, MISA_E
  li   t1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  beqz t2, 1f
  cspecialr ct2, mtdc
  csetaddr  ct1, ct2, t1
1:
  li   t2, \val
  sw   t2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(t1)
#endif
.endm

// -----------------------------------------------------------------------------

/**
 * Trap handler, for diagnostics only.
 *
 * Emits `RTRAP` or `CTRAP` depending on the mode it was entered in, followed
 * by `mcause`, and parks. Installed in direct mode before the switch, while a
 * plain `csrw` to `mtvec` is still legal. See `cheriot_smoketest.S` for why it
 * stays valid afterwards.
 */
  .section .vectors, "ax", @progbits
  .option push
  .option norvc
  .option norelax

  .balign 256
  .globl _trap_handler
  .type _trap_handler, @function
_trap_handler:
  csrr t2, misa
  andi t2, t2, MISA_E
  bnez t2, .L_trap_cheriot

  // RV32: an integer base is all the stores need.
  li   s1, TOP_UART0_BASE_ADDR
  addi t2, x0, 'R'
  j    .L_trap_mark

.L_trap_cheriot:
  // CHERIoT: narrow a copy of the memory root onto the UART register window.
  cspecialr cs1, mtdc
  li        t2, TOP_UART0_BASE_ADDR
  csetaddr  cs1, cs1, t2
  csetboundsimm cs1, cs1, 0x40
  addi      t2, x0, 'C'

.L_trap_mark:
  putr t2
  putc 'T'
  putc 'R'
  putc 'A'
  putc 'P'
  putc ' '
  csrr a2, mcause
  puthex
  put_crlf
  dv_status DV_STATUS_FAILED

.L_trap_park:
  wfi
  j    .L_trap_park
  .size _trap_handler, . - _trap_handler

  .option pop

// -----------------------------------------------------------------------------

  .section .crt, "ax", @progbits
  .balign 4
  .globl _ottf_start
  .type _ottf_start, @function
_ottf_start:
  .option push
  .option norvc
  .option norelax

  li s1, TOP_UART0_BASE_ADDR
  li tp, TOP_RV_CORE_IBEX_CFG_BASE_ADDR

  lui  t2, %hi(_trap_handler)
  addi t2, t2, %lo(_trap_handler)
  csrw mtvec, t2

  dv_status DV_STATUS_IN_TEST

  // Rendezvous 1, in RV32 mode.
  putc 'R'
  putc 'V'
  putc '3'
  putc '2'
  putc ' '
  putc 'R'
  putc 'E'
  putc 'A'
  putc 'D'
  putc 'Y'
  put_crlf
  wait_for_host rv_dm_cheriot_caps_wait_rv32

  // Switch to CHERIoT and lock the choice. See `cheriot_smoketest.S` for why
  // `CHERIOT_ENA` is read back before the lock.
  addi t2, x0, MULTIBIT_ASM_BOOL4_TRUE
  sw   t2, RV_CORE_IBEX_CHERIOT_ENA_REG_OFFSET(tp)
  lw   a3, RV_CORE_IBEX_CHERIOT_ENA_REG_OFFSET(tp)
  bne  t2, a3, _fail_ena
  sw   t2, RV_CORE_IBEX_CHERIOT_LOCK_REG_OFFSET(tp)
  fence.i
  .option pop

  csrr t2, misa
  andi t2, t2, MISA_MODE
  addi a3, x0, MISA_E
  bne  t2, a3, _fail_mode_rv32

  // MMIO now needs capabilities. `mtdc` still holds the memory root: nothing
  // before this point writes it.
  cspecialr ct1, mtdc
  li        t2, TOP_UART0_BASE_ADDR
  csetaddr  cs1, ct1, t2
  csetboundsimm cs1, cs1, 0x40

  // The capabilities under test. They are deliberately different from each
  // other, so that a debug module returning the wrong register, or only some
  // of the metadata bits, cannot pass by accident:
  //
  //   a1   the memory root itself, with every data permission
  //   s0   a data capability bounded to `rv_dm_cheriot_caps_expected`
  //   a0   derived from PCC, so it carries execute rather than store
  //        permission. `auipcc` rather than `cllc`: there is no symbol to
  //        point at, only the permissions matter, and it needs no relocation.
  cmove     ca1, ct1
  lui       t2, %hi(rv_dm_cheriot_caps_expected)
  addi      t2, t2, %lo(rv_dm_cheriot_caps_expected)
  csetaddr  cs0, ct1, t2
  csetboundsimm cs0, cs0, EXP_SIZE
  auipcc    ca0, 0
  csetboundsimm ca0, ca0, 16

  // Keep exact copies to compare against after the halt.
  cmove cgp, cs0
  cmove ctp, ca0
  cmove ct0, ca1

  // Record and report each one. `putcap` stores through `cs0`, which is also
  // one of the registers being recorded; that is fine, since the store does
  // not change it.
  putcap_prefix
  putc 's'
  putc '0'
  putcap cs0, EXP_S0
  putcap_prefix
  putc 'a'
  putc '0'
  putcap ca0, EXP_A0
  putcap_prefix
  putc 'a'
  putc '1'
  putcap ca1, EXP_A1
  // Not `ct1`: `puthex` uses `t1` as its counter and would clobber it.
  cspecialr ct2, mtdc
  putcap_prefix
  putc 'm'
  putc 't'
  putc 'd'
  putc 'c'
  putcap ct2, EXP_MTDC

  // Rendezvous 2, in CHERIoT mode.
  putc 'C'
  putc 'H'
  putc 'E'
  putc 'R'
  putc 'I'
  putc 'O'
  putc 'T'
  putc ' '
  putc 'R'
  putc 'E'
  putc 'A'
  putc 'D'
  putc 'Y'
  put_crlf
  wait_for_host rv_dm_cheriot_caps_wait_cheriot

  // Everything the host borrowed must be back exactly as it was, tag included.
  // `cseqx` compares all bits and the tag, so on its own it would already
  // catch a lost tag. The explicit tag check is there so that the two kinds of
  // corruption are not confused when reading a failure.
  cgettag a2, cs0
  beqz    a2, _fail_s0
  cseqx   a2, cs0, cgp
  beqz    a2, _fail_s0
  cgettag a2, ca0
  beqz    a2, _fail_a0
  cseqx   a2, ca0, ctp
  beqz    a2, _fail_a0
  cgettag a2, ca1
  beqz    a2, _fail_a1
  cseqx   a2, ca1, ct0
  beqz    a2, _fail_a1

  putc 'C'
  putc 'H'
  putc 'E'
  putc 'R'
  putc 'I'
  putc 'O'
  putc 'T'
  putc ' '
  putc 'D'
  putc 'E'
  putc 'B'
  putc 'U'
  putc 'G'
  putc ' '
  putc 'P'
  putc 'A'
  putc 'S'
  putc 'S'
  put_crlf
  dv_status DV_STATUS_PASSED

.L_park:
  wfi
  j    .L_park
  .size _ottf_start, . - _ottf_start

// -----------------------------------------------------------------------------

/**
 * Failure reporter. `s1` is an integer before the switch and a capability
 * after it; the stores in `putc` encode the same either way.
 */
  .balign 4
_fail_ena:
  addi a0, x0, 'E'
  j    _fail
_fail_mode_rv32:
  addi a0, x0, 'M'
  j    _fail
_fail_s0:
  addi a0, x0, 'S'
  j    _fail
_fail_a0:
  addi a0, x0, 'A'
  j    _fail
_fail_a1:
  addi a0, x0, 'B'
  j    _fail

  .type _fail, @function
_fail:
  putc 'F'
  putc 'A'
  putc 'I'
  putc 'L'
  putc ' '
  putr a0
  put_crlf
  dv_status DV_STATUS_FAILED
.L_fail_park:
  wfi
  j    .L_fail_park
  .size _fail, . - _fail

// -----------------------------------------------------------------------------

  // The capabilities under test as the core held them, recorded by `putcap`.
  // Global so that a testbench can find it in the ELF.
  .section .bss, "aw", @nobits
  .balign 8
  .globl rv_dm_cheriot_caps_expected
  .type rv_dm_cheriot_caps_expected, @object
rv_dm_cheriot_caps_expected:
  .zero EXP_SIZE
  .size rv_dm_cheriot_caps_expected, EXP_SIZE
