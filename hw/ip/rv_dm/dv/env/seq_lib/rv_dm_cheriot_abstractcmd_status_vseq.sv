// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The abstract command generation check, run in CHERIoT mode.
//
// This is the sequence that actually proves the encoding selection: the parent compares the
// generated command against a fixed expected sequence, and in this mode four of its ten words must
// be CSpecialRW rather than CSRRW.

class rv_dm_cheriot_abstractcmd_status_vseq extends rv_dm_abstractcmd_status_vseq;
  `uvm_object_utils(rv_dm_cheriot_abstractcmd_status_vseq)
  `uvm_object_new

  constraint no_cheriot_ena_c {
    cheriot_ena == 1'b1;
  }

endclass : rv_dm_cheriot_abstractcmd_status_vseq
