// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

//! Host side of the rv_dm CHERIoT capability test.
//!
//! Drives the debug module directly over DMI while `rv_dm_cheriot_caps.S` runs on the device, and
//! checks the parts of the debug module that change with the ISA mode:
//!
//! - In RV32 mode, a 64-bit Access Register command is rejected with `CmdErrNotSupported`.
//! - In CHERIoT mode, a 64-bit Access Register command returns a whole capability, address in
//!   `data0` and metadata in `data1`. That includes `s0` and `a0`, which the debug module itself
//!   borrows and so reaches through different code paths, and `mtdc`, which goes through the
//!   Special Capability Register path.
//! - A 32-bit read in CHERIoT mode still returns just the address.
//! - A 64-bit write followed by a 64-bit read round-trips the bits. The tag does not round-trip,
//!   which is a documented limitation, so it is not checked.
//!
//! The device checks the last part itself: after the halt, `s0`, `a0` and `a1` must still be
//! tagged and identical to the copies it kept.
//!
//! This uses raw DMI rather than OpenOCD's RISC-V target or GDB, because neither knows about
//! CHERIoT: they would only ever issue 32-bit register accesses to an RV32 hart.

use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use clap::Parser;

use opentitanlib::app::{TransportWrapper, UartRx};
use opentitanlib::debug::dmi::{Dmi, DmiDebugger, DmiHart, OpenOcdDmi, consts};
use opentitanlib::execute_test;
use opentitanlib::test_utils::init::InitializeTest;
use opentitanlib::uart::console::UartConsole;

#[derive(Debug, Parser)]
struct Opts {
    #[command(flatten)]
    init: InitializeTest,

    /// Console receive timeout.
    #[arg(long, value_parser = humantime::parse_duration, default_value = "60s")]
    timeout: Duration,
}

// Needs to match util/openocd/target
const RISCV_IDCODE: u32 = 0x10021cdf;

// Debug module registers not covered by `consts`.
const COMMAND: u32 = 0x17;

// Abstract command fields, for an Access Register command (cmdtype 0).
const AARSIZE_SHIFT: u32 = 20;
const TRANSFER: u32 = 1 << 17;
const WRITE: u32 = 1 << 16;
const AARSIZE_32: u32 = 2;
const AARSIZE_64: u32 = 3;

const CMDERR_NOT_SUPPORTED: u32 = 2;

// Access Register `regno` values. GPRs are 0x1000 + n. A 64-bit access to a `regno` below 0x1000
// names a Special Capability Register by its low five bits.
const REGNO_S0: u32 = 0x1008;
const REGNO_A0: u32 = 0x100a;
const REGNO_A1: u32 = 0x100b;
const REGNO_A2: u32 = 0x100c;
const REGNO_A5: u32 = 0x100f;
const REGNO_SCR_MTDC: u32 = 0x1d;

/// A capability as the debug module presents it: the address half in `data0` and the metadata
/// half in `data1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Cap {
    addr: u32,
    meta: u32,
}

/// Issue an Access Register command and return `cmderr`, clearing it if it is set.
fn access_register<D: Dmi>(
    hart: &mut DmiHart<'_, D>,
    regno: u32,
    aarsize: u32,
    write: bool,
) -> Result<u32> {
    let cmd = aarsize << AARSIZE_SHIFT | TRANSFER | if write { WRITE } else { 0 } | regno;
    hart.dmi_write(COMMAND, cmd)?;

    // The command completes when the hart has run it and re-entered the park loop. Allow plenty of
    // polls: each one is a JTAG round trip, so this is not the limiting factor.
    let mut abstractcs = hart.dmi_read(consts::ABSTRACTCS)?;
    for _ in 0..100 {
        if abstractcs & consts::ABSTRACTCS_BUSY_MASK == 0 {
            break;
        }
        abstractcs = hart.dmi_read(consts::ABSTRACTCS)?;
    }
    ensure!(
        abstractcs & consts::ABSTRACTCS_BUSY_MASK == 0,
        "abstract command {cmd:#010x} still busy"
    );

    let cmderr = (abstractcs & consts::ABSTRACTCS_CMDERR_MASK) >> consts::ABSTRACTCS_CMDERR_SHIFT;
    if cmderr != consts::ABSTRACTCS_CMDERR_NONE {
        // cmderr is write-1-to-clear.
        hart.dmi_write(consts::ABSTRACTCS, consts::ABSTRACTCS_CMDERR_MASK)?;
    }
    Ok(cmderr)
}

fn read_reg32<D: Dmi>(hart: &mut DmiHart<'_, D>, regno: u32) -> Result<u32> {
    let cmderr = access_register(hart, regno, AARSIZE_32, false)?;
    ensure!(
        cmderr == 0,
        "32-bit read of regno {regno:#x} failed, cmderr {cmderr}"
    );
    hart.data(0)
}

fn write_reg32<D: Dmi>(hart: &mut DmiHart<'_, D>, regno: u32, value: u32) -> Result<()> {
    hart.set_data(0, value)?;
    let cmderr = access_register(hart, regno, AARSIZE_32, true)?;
    ensure!(
        cmderr == 0,
        "32-bit write of regno {regno:#x} failed, cmderr {cmderr}"
    );
    Ok(())
}

fn read_cap<D: Dmi>(hart: &mut DmiHart<'_, D>, regno: u32) -> Result<Cap> {
    let cmderr = access_register(hart, regno, AARSIZE_64, false)?;
    ensure!(
        cmderr == 0,
        "64-bit read of regno {regno:#x} failed, cmderr {cmderr}"
    );
    Ok(Cap {
        addr: hart.data(0)?,
        meta: hart.data(1)?,
    })
}

fn write_cap<D: Dmi>(hart: &mut DmiHart<'_, D>, regno: u32, cap: Cap) -> Result<()> {
    hart.set_data(0, cap.addr)?;
    hart.set_data(1, cap.meta)?;
    let cmderr = access_register(hart, regno, AARSIZE_64, true)?;
    ensure!(
        cmderr == 0,
        "64-bit write of regno {regno:#x} failed, cmderr {cmderr}"
    );
    Ok(())
}

fn halt<D: Dmi>(hart: &mut DmiHart<'_, D>) -> Result<()> {
    hart.set_halt_request(true)?;
    hart.wait_halt()?;
    hart.set_halt_request(false)
}

fn resume<D: Dmi>(hart: &mut DmiHart<'_, D>) -> Result<()> {
    hart.set_resume_request(true)?;
    hart.wait_resume()?;
    hart.set_resume_request(false)
}

/// Wait for a `CAP <name> <address> <metadata>` line and return the capability it describes.
fn wait_for_cap(
    uart: &dyn opentitanlib::io::uart::Uart,
    name: &str,
    timeout: Duration,
) -> Result<Cap> {
    let caps = UartConsole::wait_for(
        uart,
        &format!(r"CAP {name} ([0-9a-f]{{8}}) ([0-9a-f]{{8}})"),
        timeout,
    )
    .with_context(|| format!("waiting for the device to report {name}"))?;
    Ok(Cap {
        addr: u32::from_str_radix(&caps[1], 16)?,
        meta: u32::from_str_radix(&caps[2], 16)?,
    })
}

fn test_cheriot_caps(opts: &Opts, transport: &TransportWrapper) -> Result<()> {
    transport.pin_strapping("PINMUX_TAP_RISCV")?.apply()?;
    transport.reset(UartRx::Clear)?;

    let uart = &*transport.uart("console")?;
    UartConsole::wait_for(uart, r"RV32 READY", opts.timeout)?;

    let mut openocd = opts.init.jtag_params.create(transport)?.into_raw()?;
    assert_eq!(
        openocd.execute(&format!(
            "jtag newtap riscv tap -irlen 5 -expected-id {RISCV_IDCODE:#x}"
        ))?,
        ""
    );
    assert_eq!(openocd.execute("init")?, "");
    let mut dmi = DmiDebugger::new(OpenOcdDmi::new(openocd, "riscv.tap")?);

    // Rendezvous 1: RV32 mode.
    {
        let mut hart = dmi.select_hart(0)?;
        hart.set_dmcontrol(consts::DMCONTROL_ACKHAVERESET_MASK)?;
        halt(&mut hart)?;

        // The device zeroes a5 before spinning on it, so a plain read tells us the 32-bit path
        // works before we rely on it to release the device.
        ensure!(
            read_reg32(&mut hart, REGNO_A5)? == 0,
            "a5 not zero at rendezvous 1"
        );

        let cmderr = access_register(&mut hart, REGNO_A1, AARSIZE_64, false)?;
        ensure!(
            cmderr == CMDERR_NOT_SUPPORTED,
            "64-bit read in RV32 mode gave cmderr {cmderr}, expected {CMDERR_NOT_SUPPORTED}"
        );
        log::info!("RV32 mode: 64-bit Access Register rejected as expected");

        write_reg32(&mut hart, REGNO_A5, 1)?;
        resume(&mut hart)?;
    }

    // Rendezvous 2: CHERIoT mode. The device reports what it holds before it says it is ready.
    let expected = [
        ("s0", REGNO_S0, wait_for_cap(uart, "s0", opts.timeout)?),
        ("a0", REGNO_A0, wait_for_cap(uart, "a0", opts.timeout)?),
        ("a1", REGNO_A1, wait_for_cap(uart, "a1", opts.timeout)?),
        (
            "mtdc",
            REGNO_SCR_MTDC,
            wait_for_cap(uart, "mtdc", opts.timeout)?,
        ),
    ];
    UartConsole::wait_for(uart, r"CHERIOT READY", opts.timeout)?;

    {
        let mut hart = dmi.select_hart(0)?;
        halt(&mut hart)?;

        let mut mismatches = Vec::new();
        for &(name, regno, exp) in &expected {
            let got = read_cap(&mut hart, regno)?;
            log::info!("{name}: expected {exp:x?}, read {got:x?}");
            if got != exp {
                mismatches.push(format!("{name}: expected {exp:x?}, read {got:x?}"));
            }

            // SCRs have no 32-bit view through Access Register, so only check GPRs here.
            if regno >= 0x1000 {
                let addr = read_reg32(&mut hart, regno)?;
                if addr != exp.addr {
                    mismatches.push(format!(
                        "{name}: 32-bit read gave {addr:#010x}, expected address {:#010x}",
                        exp.addr
                    ));
                }
            }
        }
        if !mismatches.is_empty() {
            bail!(
                "capability readback mismatches:\n  {}",
                mismatches.join("\n  ")
            );
        }

        // Write a1's bits into a2 and read them back. The device does not use a2 afterwards.
        let a1 = expected[2].2;
        write_cap(&mut hart, REGNO_A2, a1)?;
        let a2 = read_cap(&mut hart, REGNO_A2)?;
        ensure!(
            a2 == a1,
            "64-bit write/read round trip through a2: wrote {a1:x?}, read {a2:x?}"
        );
        log::info!("64-bit write/read round trip OK");

        write_reg32(&mut hart, REGNO_A5, 1)?;
        resume(&mut hart)?;
    }

    // The device checks that s0, a0 and a1 came back intact, tags included.
    let result = UartConsole::wait_for(
        uart,
        r"(CHERIOT DEBUG PASS|FAIL .|[RC]TRAP [0-9a-f]{8})",
        opts.timeout,
    )?;
    ensure!(
        result[1] == "CHERIOT DEBUG PASS",
        "device reported {:?} after the CHERIoT-mode halt",
        result[1]
    );
    Ok(())
}

fn main() -> Result<()> {
    let opts = Opts::parse();
    opts.init.init_logging();
    let transport = opts.init.init_target()?;

    execute_test!(test_cheriot_caps, &opts, &transport);

    Ok(())
}
