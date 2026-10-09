// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Drives the debug module over JTAG before and after the core switches to CHERIoT, and checks the
// parts of it that change with the ISA mode.
//
// The software is `sw/device/tests/rv_dm_cheriot_caps.S`. It stops twice, spinning on `a5` at a
// global symbol, and this sequence takes over at each stop:
//
// 1. `rv_dm_cheriot_caps_wait_rv32`, in RV32 mode. A 64-bit Access Register command must be
//    rejected, and a 32-bit one must work.
// 2. `rv_dm_cheriot_caps_wait_cheriot`, in CHERIoT mode. 64-bit reads of `s0`, `a0`, `a1` and
//    `mtdc` must return the capabilities the software recorded in `rv_dm_cheriot_caps_expected`
//    just before it stopped. A 32-bit read must return the address half. A read of x16, which
//    CHERIoT's RV32E does not have, must end in an exception rather than hang. A 64-bit write
//    followed by a 64-bit read must round-trip the bits.
//
// Every abstract command needs the hart to run the debug ROM's park loop and the generated
// command, so any of these steps also checks that the CHERIoT park loop agrees with the debug
// module on its memory layout. The x16 read additionally takes the park loop's exception entry.
//
// After the second stop, the software checks that `s0`, `a0` and `a1` came back with their tags
// and every bit intact, and reports the result through the DV test status window. `s0` and `a0`
// are the registers the debug module borrows while it runs, so this is what checks that it saves
// and restores them as whole capabilities. Capability tags cannot be read or written over the
// debug module, so that check has to live in the software.
class chip_sw_rv_dm_cheriot_caps_vseq extends chip_sw_base_vseq;
  `uvm_object_utils(chip_sw_rv_dm_cheriot_caps_vseq)
  `uvm_object_new

  // Access Register regno values. GPR xn is 0x1000 + n.
  localparam abstract_cmd_regno_t RegnoS0  = 'h1008;
  localparam abstract_cmd_regno_t RegnoA0  = 'h100a;
  localparam abstract_cmd_regno_t RegnoA1  = 'h100b;
  localparam abstract_cmd_regno_t RegnoA2  = 'h100c;
  localparam abstract_cmd_regno_t RegnoA5  = 'h100f;
  localparam abstract_cmd_regno_t RegnoX16 = 'h1010;
  // A 64-bit access to a regno below 0x1000 names a Special Capability Register by its low five
  // bits. 29 is mtdc.
  localparam abstract_cmd_regno_t RegnoScrMtdc = 'h1d;

  // Order of the capabilities in `rv_dm_cheriot_caps_expected`, eight bytes each.
  localparam int unsigned ExpS0   = 0;
  localparam int unsigned ExpA0   = 1;
  localparam int unsigned ExpA1   = 2;
  localparam int unsigned ExpMtdc = 3;
  localparam int unsigned NumExp  = 4;

  string elf_file;

  virtual task pre_start();
    cfg.chip_vif.tap_straps_if.drive(JtagTapRvDm);
    super.pre_start();
  endtask

  // Returns the address of a symbol in the software image.
  virtual function longint unsigned symbol_addr(string symbol);
    longint unsigned addr, size;
    `DV_CHECK(dv_utils_pkg::sw_symbol_get_addr_size(.elf_file(elf_file), .symbol(symbol),
                                                    .does_not_exist_ok(0), .addr(addr),
                                                    .size(size)))
    return addr;
  endfunction

  // Waits for the software to reach one of its stops.
  virtual task wait_for_stop(string symbol);
    longint unsigned addr = symbol_addr(symbol);
    `uvm_info(`gfn, $sformatf("Waiting for the CPU to reach %s (0x%0h)", symbol, addr), UVM_LOW)
    `DV_WAIT(cfg.chip_vif.probed_cpu_pc.pc_id == addr,
             $sformatf("Timed out waiting for the CPU to reach %s", symbol),
             cfg.sw_test_timeout_ns)
    `uvm_info(`gfn, $sformatf("The CPU reached %s", symbol), UVM_LOW)
  endtask

  // Activates the debug module and checks that the activation took.
  //
  // The debug module only accepts DMI writes once life cycle has enabled debug, so a write made
  // during boot can be dropped without any error. Every later dmcontrol write would then keep
  // dmactive clear and the halt request would be ignored, which shows up only as a timeout in
  // wait_cpu_halted. Reading dmactive back turns that into a clear failure here.
  virtual task activate_debug_module();
    uvm_reg_data_t rw_data;
    cfg.debugger.set_dmactive(1);
    csr_rd(.ptr(jtag_dmi_ral.dmcontrol), .value(rw_data), .blocking(1));
    `DV_CHECK_EQ(dv_base_reg_pkg::get_field_val(jtag_dmi_ral.dmcontrol.dmactive, rw_data), 1,
                 "dmcontrol.dmactive did not read back as set")
  endtask

  // Halts the hart, which the software has parked at one of its stops.
  virtual task halt();
    `uvm_info(`gfn, "Halting the CPU", UVM_LOW)
    cfg.debugger.set_haltreq(1);
    cfg.debugger.wait_cpu_halted();
    cfg.debugger.set_haltreq(0);
  endtask

  // Lets the software past its current stop by setting a5, then resumes the hart.
  virtual task release_and_resume();
    abstract_cmd_err_e status;
    cfg.debugger.abstract_cmd_reg_write(.regno(RegnoA5), .value_q({32'h1}), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrNone)
    cfg.debugger.set_resumereq(1);
    cfg.debugger.wait_cpu_resumed();
    cfg.debugger.set_resumereq(0);
  endtask

  // Checks a 64-bit read of regno against an expected capability.
  virtual task check_cap(string name, abstract_cmd_regno_t regno, logic [63:0] exp);
    abstract_cmd_err_e status;
    logic [63:0] act;
    cfg.debugger.abstract_cmd_reg_read64(.regno(regno), .value(act), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrNone,
                 $sformatf("64-bit read of %s", name))
    `DV_CHECK_EQ(act, exp, $sformatf("64-bit read of %s (address 31:0, metadata 63:32)", name))
  endtask

  virtual task body();
    abstract_cmd_err_e status;
    sba_access_err_e sba_status;
    logic [BUS_DW-1:0] data_q[$];
    logic [63:0] exp[NumExp];
    logic [63:0] act;
    longint unsigned exp_addr;

    super.body();
    elf_file = {cfg.sw_images[SwTypeTestSlotA], ".elf"};

    //////////////////////////
    // Stop 1: RV32 mode    //
    //////////////////////////

    wait_for_stop("rv_dm_cheriot_caps_wait_rv32");
    // Activate only now: the software is running, so boot is over and life cycle has long since
    // enabled debug.
    activate_debug_module();
    halt();

    `uvm_info(`gfn, "RV32 mode: a 64-bit Access Register command must be rejected", UVM_LOW)
    cfg.debugger.abstract_cmd_reg_read64(.regno(RegnoA1), .value(act), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrUnsupported)

    `uvm_info(`gfn, "RV32 mode: a 32-bit read of a5 must work, and a5 must be 0", UVM_LOW)
    cfg.debugger.abstract_cmd_reg_read(.regno(RegnoA5), .value_q(data_q), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrNone)
    `DV_CHECK_EQ(data_q[0], 0)

    release_and_resume();

    //////////////////////////
    // Stop 2: CHERIoT mode //
    //////////////////////////

    wait_for_stop("rv_dm_cheriot_caps_wait_cheriot");
    halt();

    // The software stored the capabilities before stopping. Read them back over SBA, which sees
    // the bits but not the tags. That is all the comparison below needs.
    exp_addr = symbol_addr("rv_dm_cheriot_caps_expected");
    cfg.debugger.sba_read(.addr(exp_addr), .value_q(data_q), .status(sba_status),
                          .size(2 * NumExp));
    `DV_CHECK_EQ(sba_status, jtag_rv_debugger_pkg::SbaErrNone)
    foreach (exp[i]) begin
      exp[i] = {data_q[2 * i + 1], data_q[2 * i]};
      `uvm_info(`gfn, $sformatf("Expected capability %0d: 0x%016h", i, exp[i]), UVM_LOW)
    end

    // Sanity-check what the software recorded, so that a broken recording cannot make the
    // comparisons below pass or fail for the wrong reason. s0 is bounded to the table itself, and
    // a1 is a copy of the memory root, mtdc.
    `DV_CHECK_EQ(exp[ExpS0][31:0], exp_addr[31:0])
    `DV_CHECK_EQ(exp[ExpA1], exp[ExpMtdc])

    `uvm_info(`gfn, "CHERIoT mode: 64-bit reads must return whole capabilities", UVM_LOW)
    check_cap("s0", RegnoS0, exp[ExpS0]);
    check_cap("a0", RegnoA0, exp[ExpA0]);
    check_cap("a1", RegnoA1, exp[ExpA1]);
    check_cap("mtdc", RegnoScrMtdc, exp[ExpMtdc]);

    `uvm_info(`gfn, "CHERIoT mode: 32-bit reads must return the address half", UVM_LOW)
    cfg.debugger.abstract_cmd_reg_read(.regno(RegnoA1), .value_q(data_q), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrNone)
    `DV_CHECK_EQ(data_q[0], exp[ExpA1][31:0])

    // x16 does not exist in CHERIoT mode, so the generated command faults. This must end in
    // CmdErrException via the park loop's exception entry, not in a hang.
    `uvm_info(`gfn, "CHERIoT mode: a read of x16 must end in an exception", UVM_LOW)
    cfg.debugger.abstract_cmd_reg_read(.regno(RegnoX16), .value_q(data_q), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrException)

    // The debug module cannot carry a tag, so a2 comes back untagged, but every bit must match.
    // The software does not use a2 after this stop.
    `uvm_info(`gfn, "CHERIoT mode: a 64-bit write must round-trip through a2", UVM_LOW)
    cfg.debugger.abstract_cmd_reg_write64(.regno(RegnoA2), .value(exp[ExpA1]), .status(status));
    `DV_CHECK_EQ(status, jtag_rv_debugger_pkg::AbstractCmdErrNone)
    check_cap("a2", RegnoA2, exp[ExpA1]);

    // The software now checks that s0, a0 and a1 survived the halt with their tags, and reports
    // through the DV test status window. The base sequence's end-of-test handling picks that up.
    release_and_resume();
  endtask

endclass : chip_sw_rv_dm_cheriot_caps_vseq
