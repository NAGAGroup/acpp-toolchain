#!/bin/sh
# AdaptiveCpp ROCm backend activation.
#
# Sources after the base (10-) by filename, and sets a disjoint pair, so it
# layers rather than overriding.
#
# ACPP_ROCM_LIB_PATH exists as a setting for the same reason as the CUDA one:
# the driver derives the library directory as lib inside the ROCm
# installation, which is the vendor layout rather than the conda one.

if [ "${CONDA_BUILD:-0}" = "1" ]; then
  _acpp_rocm_root="${PREFIX}"
else
  _acpp_rocm_root="${CONDA_PREFIX}"
fi

if [ -n "${ACPP_ROCM_PATH:-}" ]; then
  _CONDA_BACKUP_ACPP_ROCM_PATH="${ACPP_ROCM_PATH}"
  export _CONDA_BACKUP_ACPP_ROCM_PATH
fi
if [ -n "${ACPP_ROCM_LIB_PATH:-}" ]; then
  _CONDA_BACKUP_ACPP_ROCM_LIB_PATH="${ACPP_ROCM_LIB_PATH}"
  export _CONDA_BACKUP_ACPP_ROCM_LIB_PATH
fi

export ACPP_ROCM_PATH="${_acpp_rocm_root}"
export ACPP_ROCM_LIB_PATH="${_acpp_rocm_root}/lib"

unset _acpp_rocm_root
