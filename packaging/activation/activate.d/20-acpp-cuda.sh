#!/bin/sh
# AdaptiveCpp CUDA backend activation.
#
# Sources after the base (10-) by filename. It sets a disjoint pair of
# variables, so it layers rather than overriding anything the base set.
#
# ACPP_CUDA_LIB_PATH exists as a setting precisely for this case: the driver
# otherwise derives the library directory as lib64 inside the CUDA
# installation, which is the layout a vendor installer produces. conda-forge
# puts the runtime in <prefix>/lib, so the derivation is wrong here and the
# whole link line would have to be replaced to correct it.

if [ "${CONDA_BUILD:-0}" = "1" ]; then
  _acpp_cuda_root="${PREFIX}"
else
  _acpp_cuda_root="${CONDA_PREFIX}"
fi

if [ -n "${ACPP_CUDA_PATH:-}" ]; then
  _CONDA_BACKUP_ACPP_CUDA_PATH="${ACPP_CUDA_PATH}"
  export _CONDA_BACKUP_ACPP_CUDA_PATH
fi
if [ -n "${ACPP_CUDA_LIB_PATH:-}" ]; then
  _CONDA_BACKUP_ACPP_CUDA_LIB_PATH="${ACPP_CUDA_LIB_PATH}"
  export _CONDA_BACKUP_ACPP_CUDA_LIB_PATH
fi

export ACPP_CUDA_PATH="${_acpp_cuda_root}"
export ACPP_CUDA_LIB_PATH="${_acpp_cuda_root}/lib"

unset _acpp_cuda_root
