#!/usr/bin/env bash
# etc/conda/activate.d/acpp-runtime-activate.sh (win-64 variant)
#
# Backend device-bitcode wiring, run on environment activation. Backends
# are OPT-IN: this only copies bitcode when the corresponding runtime
# metapackage (acpp-runtime-cuda / ...) has installed the provider.
# Windows conda layout: everything lives under Library/. (Copy, not
# symlink: symlinks need elevation/dev-mode on Windows.)

ACPP_EXT_BITCODE="${CONDA_PREFIX}/Library/lib/hipSYCL/ext/bitcode"

# CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
if [ -f "${CONDA_PREFIX}/Library/nvvm/libdevice/libdevice.10.bc" ]; then
  mkdir -p "${ACPP_EXT_BITCODE}/ptx"
  cp -f "${CONDA_PREFIX}/Library/nvvm/libdevice/libdevice.10.bc" \
    "${ACPP_EXT_BITCODE}/ptx/libdevice.10.bc"
fi
