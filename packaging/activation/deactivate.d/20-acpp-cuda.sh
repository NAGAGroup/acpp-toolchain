#!/bin/sh
# Restore rather than unset: leaving a nested environment must not break an
# outer one that also set these.

if [ -n "${_CONDA_BACKUP_ACPP_CUDA_PATH:-}" ]; then
  export ACPP_CUDA_PATH="${_CONDA_BACKUP_ACPP_CUDA_PATH}"
  unset _CONDA_BACKUP_ACPP_CUDA_PATH
else
  unset ACPP_CUDA_PATH
fi

if [ -n "${_CONDA_BACKUP_ACPP_CUDA_LIB_PATH:-}" ]; then
  export ACPP_CUDA_LIB_PATH="${_CONDA_BACKUP_ACPP_CUDA_LIB_PATH}"
  unset _CONDA_BACKUP_ACPP_CUDA_LIB_PATH
else
  unset ACPP_CUDA_LIB_PATH
fi
