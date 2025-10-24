# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# --- MODIFICATION ---
# Load 'new_local_repository' instead of 'http_archive'
load("@bazel_tools//tools/build_defs/repo:local.bzl", "new_local_repository")

def _lowrisc_repos():
    # --- MODIFICATION ---
    # Use new_local_repository to point to your local path
    new_local_repository(
        name = "lowrisc_rv32imcb_toolchain",

        # --- YOUR CHANGE HERE ---
        # Set this to the absolute path of your toolchain installation
        path = "/scratch/sriedel/lowrisc-toolchains/out/lowrisc-toolchain-rv32imcbzc-x86_64/",

        # This points to the BUILD file you downloaded in step 1.
        # It defines the toolchain for Bazel.
        build_file = ":BUILD.lowrisc_rv32imcb_toolchain.bazel",
    )

lowrisc_rv32imcb_toolchain = module_extension(
    implementation = lambda _: _lowrisc_repos(),
)
