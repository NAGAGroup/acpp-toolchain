#!/bin/sh
# AdaptiveCpp base activation.
#
# Our fork omits from the generated configuration every setting that names a
# path outside the AdaptiveCpp installation, because the path a build machine
# used is wrong in a redistributable package - the driver reports the setting
# missing by name rather than resolving a directory that is not there. This
# supplies the three that always point inside our own prefix.
#
# The CUDA and ROCm pairs belong to their backend packages, which source later
# by filename. We ship no nvhpc, so ACPP_NVCXX stays unset.

# During a conda BUILD the compiler is a build-platform tool and lives in the
# build prefix, while the headers it must match belong to the host prefix.
# Outside a build the two collapse to a single prefix.
if [ "${CONDA_BUILD:-0}" = "1" ]; then
  _acpp_cxx="${BUILD_PREFIX}/bin/clang++"
  _acpp_inc="${PREFIX}/lib/clang/LLVM_MAJOR/include"
else
  _acpp_cxx="${CONDA_PREFIX}/bin/clang++"
  _acpp_inc="${CONDA_PREFIX}/lib/clang/LLVM_MAJOR/include"
fi

# Any prior value is saved so that a compiler activation package - which
# sources later - can override ACPP_CPU_CXX and have deactivation restore this
# one rather than unset it.
if [ -n "${ACPP_CLANG:-}" ]; then
  _CONDA_BACKUP_ACPP_CLANG="${ACPP_CLANG}"
  export _CONDA_BACKUP_ACPP_CLANG
fi
if [ -n "${ACPP_CPU_CXX:-}" ]; then
  _CONDA_BACKUP_ACPP_CPU_CXX="${ACPP_CPU_CXX}"
  export _CONDA_BACKUP_ACPP_CPU_CXX
fi
if [ -n "${ACPP_CLANG_INCLUDE_PATH:-}" ]; then
  _CONDA_BACKUP_ACPP_CLANG_INCLUDE_PATH="${ACPP_CLANG_INCLUDE_PATH}"
  export _CONDA_BACKUP_ACPP_CLANG_INCLUDE_PATH
fi

# ACPP_CLANG is not a user choice: the AdaptiveCpp clang plugin is ABI-bound to
# the clang it was compiled against, which is the one we ship. ACPP_CPU_CXX is
# the host compiler, and is the one an activation package may override.
export ACPP_CLANG="${_acpp_cxx}"
export ACPP_CPU_CXX="${_acpp_cxx}"
export ACPP_CLANG_INCLUDE_PATH="${_acpp_inc}"

unset _acpp_cxx _acpp_inc
