#!/usr/bin/env bash
# etc/conda/activate.d/acpp-runtime-activate.sh (win-64 variant)
#
# Backend device-bitcode wiring, run on environment activation. Backends
# are OPT-IN: this only copies bitcode when the corresponding runtime
# metapackage (acpp-runtime-cuda / ...) has installed the provider.
# Windows conda layout: everything lives under Library/. (Copy, not
# symlink: symlinks need elevation/dev-mode on Windows.)

ACPP_EXT_BITCODE="${CONDA_PREFIX}/Library/bin/hipSYCL/ext/bitcode"

# NB Library\bin, NOT Library\lib: acpp resolves its bitcode dir from
# get_lib_directory(), which on Windows is the directory containing
# acpp-common.dll (GetModuleHandleA) -- i.e. Library\bin, since DLLs are
# RUNTIME artifacts there. Using lib/ makes acpp fall back to the
# build-time CUDA path baked into the binary, which does not exist at
# runtime (win gets no binary prefix replacement).
# CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
if [ -f "${CONDA_PREFIX}/Library/nvvm/libdevice/libdevice.10.bc" ]; then
  mkdir -p "${ACPP_EXT_BITCODE}/ptx"
  cp -f "${CONDA_PREFIX}/Library/nvvm/libdevice/libdevice.10.bc" \
    "${ACPP_EXT_BITCODE}/ptx/libdevice.10.bc"
fi
