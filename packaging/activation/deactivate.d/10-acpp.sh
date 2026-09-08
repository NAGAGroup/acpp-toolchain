#!/bin/sh
# Restore rather than unset: leaving a nested environment must not break an
# outer one that also set these.

if [ -n "${_CONDA_BACKUP_ACPP_CLANG:-}" ]; then
  export ACPP_CLANG="${_CONDA_BACKUP_ACPP_CLANG}"
  unset _CONDA_BACKUP_ACPP_CLANG
else
  unset ACPP_CLANG
fi

if [ -n "${_CONDA_BACKUP_ACPP_CPU_CXX:-}" ]; then
  export ACPP_CPU_CXX="${_CONDA_BACKUP_ACPP_CPU_CXX}"
  unset _CONDA_BACKUP_ACPP_CPU_CXX
else
  unset ACPP_CPU_CXX
fi

if [ -n "${_CONDA_BACKUP_ACPP_CLANG_INCLUDE_PATH:-}" ]; then
  export ACPP_CLANG_INCLUDE_PATH="${_CONDA_BACKUP_ACPP_CLANG_INCLUDE_PATH}"
  unset _CONDA_BACKUP_ACPP_CLANG_INCLUDE_PATH
else
  unset ACPP_CLANG_INCLUDE_PATH
fi
