// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class rv_dm_rom_read_access_vseq extends rv_dm_base_vseq;
  `uvm_object_utils(rv_dm_rom_read_access_vseq)
  `uvm_object_new

  // Sizes of the two debug ROMs, in 64-bit words. These are implementation details of the debug
  // ROMs: they are the RomSize localparams in debug_rom.sv and debug_rom_cheriot.sv, and they will
  // change if either ROM is reassembled. There is no way to read a localparam over the bus,
  // so they are repeated here and the check below will fail loudly if they drift.
  localparam int unsigned RomSizeRv32   = 20;
  localparam int unsigned RomSizeCheriot = 20;

  task body();
    string         path;
    bit [31:0]     lower_mem_val;
    bit [31:0]     upper_mem_val;
    uvm_reg_data_t mem_val;
    uvm_reg_data_t rom_data;

    // The debug module holds both ROMs and selects between them, so read back whichever one the
    // current mode should be presenting.
    string rom_inst = cheriot_ena ? "gen_cheriot_rom.i_debug_rom_cheriot" : "i_debug_rom";
    int unsigned rom_size = cheriot_ena ? RomSizeCheriot : RomSizeRv32;

    repeat (2) begin
      for (int i = 0; i < rom_size; i++) begin
        path = $sformatf("tb.dut.u_dm_top.i_dm_mem.gen_rom_snd_scratch.%0s.mem[%0d]", rom_inst, i);
        `DV_CHECK(uvm_hdl_read(path, rom_data))
        mem_rd(.ptr(tl_mem_ral.rom), .offset(i*2), .data(lower_mem_val));
        mem_rd(.ptr(tl_mem_ral.rom), .offset(i*2+1), .data(upper_mem_val));
        mem_val = {upper_mem_val, lower_mem_val};
        `DV_CHECK_EQ(mem_val, rom_data,
                     $sformatf("ROM word %0d mismatches %0s (cheriot_ena=%0b)",
                               i, rom_inst, cheriot_ena))
      end
    end
  endtask

endclass : rv_dm_rom_read_access_vseq
