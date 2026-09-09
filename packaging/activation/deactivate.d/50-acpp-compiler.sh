#!/bin/sh
# Reverses 50-acpp-compiler.sh.
#
# Restore rather than unset, in every case. ACPP_CPU_CXX in particular was set
# by the base package's 10-acpp.sh before this one overrode it, so unsetting
# would leave acpp with no host compiler in an environment that still has the
# base installed.

_acpp_restore() {
  for _acpp_name in "$@"; do
    eval "_acpp_old=\${CONDA_BACKUP_${_acpp_name}:-}"
    if [ -n "${_acpp_old:-}" ]; then
      eval "export ${_acpp_name}=\"\${_acpp_old}\""
    else
      eval "unset ${_acpp_name}"
    fi
    eval "unset CONDA_BACKUP_${_acpp_name}"
  done
}

_acpp_restore \
  HOST BUILD host_alias build_alias \
  CONDA_TOOLCHAIN_HOST CONDA_TOOLCHAIN_BUILD \
  CC CXX CPP CLANG CLANGXX \
  CC_FOR_BUILD CXX_FOR_BUILD CPP_FOR_BUILD \
  CPPFLAGS CFLAGS CXXFLAGS \
  DEBUG_CPPFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS \
  LDFLAGS LDFLAGS_LD \
  CMAKE_PREFIX_PATH CMAKE_ARGS MESON_ARGS \
  CONDA_BUILD_SYSROOT \
  ACPP_CPU_CXX

unset _acpp_name _acpp_old
unset -f _acpp_restore 2>/dev/null || true
