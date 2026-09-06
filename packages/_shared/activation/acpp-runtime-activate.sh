#!/usr/bin/env bash
# etc/conda/activate.d/acpp-runtime-activate.sh
#
# Backend device-bitcode wiring, run on environment activation. Backends
# are OPT-IN: this only creates symlinks when the corresponding runtime
# metapackage (acpp-runtime-cuda / …) has installed the bitcode provider.

ACPP_EXT_BITCODE="${CONDA_PREFIX}/lib/hipSYCL/ext/bitcode"

# CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
if [ -f "${CONDA_PREFIX}/nvvm/libdevice/libdevice.10.bc" ]; then
  mkdir -p "${ACPP_EXT_BITCODE}/ptx"
  ln -sf "${CONDA_PREFIX}/nvvm/libdevice/libdevice.10.bc" \
    "${ACPP_EXT_BITCODE}/ptx/libdevice.10.bc"
fi
