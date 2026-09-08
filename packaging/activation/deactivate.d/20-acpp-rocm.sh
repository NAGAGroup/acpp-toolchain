#!/bin/sh
# Restore rather than unset: leaving a nested environment must not break an
# outer one that also set these.

if [ -n "${_CONDA_BACKUP_ACPP_ROCM_PATH:-}" ]; then
  export ACPP_ROCM_PATH="${_CONDA_BACKUP_ACPP_ROCM_PATH}"
  unset _CONDA_BACKUP_ACPP_ROCM_PATH
else
  unset ACPP_ROCM_PATH
fi

if [ -n "${_CONDA_BACKUP_ACPP_ROCM_LIB_PATH:-}" ]; then
  export ACPP_ROCM_LIB_PATH="${_CONDA_BACKUP_ACPP_ROCM_LIB_PATH}"
  unset _CONDA_BACKUP_ACPP_ROCM_LIB_PATH
else
  unset ACPP_ROCM_LIB_PATH
fi
