// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The halt/resume/whereto flow, run in CHERIoT mode.
//
// Nothing in the parent sequence is mode-dependent, which is the point: the whereto word is
// bit-identical in both ISAs because CHERIoT reuses the jal encoding for CJAL. Running it here
// turns that from an assumption into something the regression checks.

class rv_dm_cheriot_halt_resume_whereto_vseq extends rv_dm_halt_resume_whereto_vseq;
  `uvm_object_utils(rv_dm_cheriot_halt_resume_whereto_vseq)
  `uvm_object_new

  constraint no_cheriot_ena_c {
    cheriot_ena == 1'b1;
  }

endclass : rv_dm_cheriot_halt_resume_whereto_vseq
