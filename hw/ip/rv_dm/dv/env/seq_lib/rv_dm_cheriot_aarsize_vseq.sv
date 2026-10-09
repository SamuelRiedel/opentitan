// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Check that 64-bit Access Register commands are accepted exactly when the ISA can express them.
//
// aarsize == 3 asks for a 64-bit register transfer. On a 32-bit hart executing RV32I that is
// meaningless and must be rejected with CmdErrNotSupported. In CHERIoT mode the same size selects
// a capability-wide transfer, moving a capability's address and metadata together, and is how a
// debugger reaches capability metadata at all, so it must be accepted.
//
// This sequence runs in both modes and checks both outcomes, because getting either half wrong is
// silently damaging: rejecting it in CHERIoT mode makes capability metadata unreachable, and
// accepting it in RV32I mode makes the hart trap on a load it cannot execute, turning a clean
// "not supported" answer into a spurious exception.

class rv_dm_cheriot_aarsize_vseq extends rv_dm_base_vseq;
  `uvm_object_utils(rv_dm_cheriot_aarsize_vseq)
  `uvm_object_new

  // Exercise both modes. This overrides the base class constraint that pins the mode to RV32I.
  constraint no_cheriot_ena_c {
    cheriot_ena dist { 1'b0 :/ 1, 1'b1 :/ 1 };
  }

  // Build an Access Register read command of the given size. The default regno is GPR s0.
  function command_t gen_sized_read_cmd(bit [2:0] aarsize, bit [15:0] regno = 16'h1008);
    command_t   cmd;
    ac_ar_cmd_t ar_cmd = '0;

    ar_cmd.aarsize          = aarsize;
    ar_cmd.aarpostincrement = 0;
    ar_cmd.postexec         = 0;
    ar_cmd.transfer         = 1;
    ar_cmd.write            = 0;
    ar_cmd.regno            = regno;

    cmd.cmdtype = AccessRegister;
    cmd.control = ar_cmd;
    return cmd;
  endfunction

  // Play the part of the halted hart running the abstract command and re-entering debug mode.
  //
  // This is needed because an accepted command leaves the debug module busy until the hart
  // responds: its state machine goes Idle -> Go on the command write, Go -> CmdExecuting when the
  // hart writes GOING, and back to Idle when it writes HALTED. Without this, a second command
  // would be answered with CmdErrBusy and would tell us nothing about the size handling.
  task complete_command();
    csr_wr(.ptr(tl_mem_ral.going), .value(0));
    if (!cfg.clk_rst_vif.rst_n) return;
    csr_wr(.ptr(tl_mem_ral.halted), .value(0));
  endtask

  // Issue cmd, check the resulting cmderr, and leave the debug module ready for the next command.
  //
  // A rejected command never leaves the Idle state, so it needs no hart handshake; an accepted one
  // does.
  task issue_and_check(command_t cmd, cmderr_e exp_cmderr, string desc);
    csr_wr(.ptr(jtag_dmi_ral.command), .value(cmd));
    if (!cfg.clk_rst_vif.rst_n) return;

    `uvm_info(`gfn, $sformatf("%0s (cheriot_ena=%0b): expecting cmderr %0s",
                              desc, cheriot_ena, exp_cmderr.name()), UVM_LOW)
    check_cmderr(exp_cmderr);
    if (!cfg.clk_rst_vif.rst_n) return;

    if (exp_cmderr == CmdErrNone) begin
      complete_command();
      if (!cfg.clk_rst_vif.rst_n) return;
    end

    clear_cmderr();
  endtask

  task body();
    request_halt();
    if (!cfg.clk_rst_vif.rst_n) return;

    // A 32-bit transfer is supported in both modes. Checking it first means that a failure on the
    // 64-bit case below is clearly about the size, and not about the command being malformed or
    // the hart handshake being wrong.
    issue_and_check(gen_sized_read_cmd(3'd2), CmdErrNone, "32-bit access register");
    if (!cfg.clk_rst_vif.rst_n) return;

    // The 64-bit transfer is the mode-dependent one.
    issue_and_check(gen_sized_read_cmd(3'd3),
                    cheriot_ena ? CmdErrNone : CmdErrNotSupported,
                    "64-bit access register");
    if (!cfg.clk_rst_vif.rst_n) return;

    // A 64-bit CSR access names an SCR in CHERIoT mode. Only regno 0x0-0x1f are SCRs.
    issue_and_check(gen_sized_read_cmd(3'd3, 16'h001d),
                    cheriot_ena ? CmdErrNone : CmdErrNotSupported,
                    "64-bit access to SCR mtdc");
    if (!cfg.clk_rst_vif.rst_n) return;
    issue_and_check(gen_sized_read_cmd(3'd3, 16'h07b0), CmdErrNotSupported,
                    "64-bit access to CSR dcsr");
  endtask

endclass : rv_dm_cheriot_aarsize_vseq
