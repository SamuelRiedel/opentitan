// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The debug ROM read check, run against the CHERIoT park loop instead of the RV32I one.
//
// The parent sequence already selects the ROM instance and length from the mode, so all this
// needs to do is put the debug module into CHERIoT mode.

class rv_dm_cheriot_rom_read_access_vseq extends rv_dm_rom_read_access_vseq;
  `uvm_object_utils(rv_dm_cheriot_rom_read_access_vseq)
  `uvm_object_new

  constraint no_cheriot_ena_c {
    cheriot_ena == 1'b1;
  }

endclass : rv_dm_cheriot_rom_read_access_vseq
