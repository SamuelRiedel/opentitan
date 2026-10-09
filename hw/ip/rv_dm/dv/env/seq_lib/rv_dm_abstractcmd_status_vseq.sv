// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class rv_dm_abstractcmd_status_vseq extends rv_dm_base_vseq;
  `uvm_object_utils(rv_dm_abstractcmd_status_vseq)
  `uvm_object_new

  // The expected contents of the debug ROM that we will read through the abstract command
  // interface, for a hart executing RV32I.
  //
  // The command issued below has aarsize 2, transfer and write set, and regno 0, so the debug
  // module emits the "data register to CSR" sequence: save a0 to dscratch1, derive the DM base
  // into a0, save s0 to dscratch0, load the value from the data register, write it to the target
  // CSR, restore s0, restore a0, ebreak.
  bit [31:0] exp_debug_rom_rv32[10] = { 'h7b351073, 'h00000517, 'h00c55513, 'h00c51513,
                                        'h7b241073, 'h38052403, 'h00041073, 'h7b202473,
                                        'h7b302573, 'h00100073 };

  // The same sequence for a hart executing CHERIoT. Only the four debug scratch register accesses
  // change, becoming CSpecialRW:
  //
  //   [0] csrw dscratch1, a0  -> cspecialw scr26, ca0   (save a0)
  //   [4] csrw dscratch0, s0  -> cspecialw scr25, cs0   (save s0)
  //   [7] csrr s0, dscratch0  -> cspecialr cs0, scr25   (restore s0)
  //   [8] csrr a0, dscratch1  -> cspecialr ca0, scr26   (restore a0)
  //
  // Word 6 deliberately does not change. It is the write to the CSR the debugger actually named,
  // not a scratch spill, so it stays a CSR access in both modes. If a change to dm_mem ever made
  // that word mode-dependent, this test would catch it.
  //
  // These encodings are not merely what dm_pkg's helpers produce: they were cross-checked against
  // debug_rom_cheriot.dump, where the same four instructions appear in the CHERIoT debug ROM
  // (0x0394005b at 0x810 and 0x03a5005b at 0x814, 0x0390045b and 0x03a0055b at 0x864 and 0x868).
  bit [31:0] exp_debug_rom_cheriot[10] = { 'h03a5005b, 'h00000517, 'h00c55513, 'h00c51513,
                                           'h0394005b, 'h38052403, 'h00041073, 'h0390045b,
                                           'h03a0055b, 'h00100073 };

  task body();
    uvm_reg_data_t r_data;
    bit [31:0] exp_debug_rom[10];

    // Selected element by element rather than with a conditional on the arrays themselves, because
    // a ternary operator over unpacked arrays is not portable across simulators.
    foreach (exp_debug_rom[i]) begin
      exp_debug_rom[i] = cheriot_ena ? exp_debug_rom_cheriot[i] : exp_debug_rom_rv32[i];
    end

    request_halt();
    // The value in 'command' is access register command to send valid abstract command.
    csr_wr(.ptr(jtag_dmi_ral.command), .value('h00AB0000));
    csr_rd(.ptr(jtag_dmi_ral.abstractcs), .value(r_data));
    `DV_CHECK_EQ(1, get_field_val(jtag_dmi_ral.abstractcs.busy, r_data));

    for (int i = 0; i < 10; i++) begin
      csr_rd(.ptr(tl_mem_ral.abstractcmd[i]), .value(r_data));
      `DV_CHECK_EQ(exp_debug_rom[i], r_data,
                   $sformatf("abstract command word %0d (cheriot_ena=%0b)", i, cheriot_ena))
    end
  endtask

endclass : rv_dm_abstractcmd_status_vseq
