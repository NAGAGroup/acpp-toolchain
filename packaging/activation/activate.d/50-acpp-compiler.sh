#!/bin/sh
# AdaptiveCpp compiler activation - the package consumed as
# `[cxx_compiler] - "acpp"`.
#
# Sources after the base (10-) by filename, and deliberately overrides
# ACPP_CPU_CXX, which the base set to our plain clang++. The base saved its
# value, so deactivation restores it rather than unsetting it.
#
# Modelled on conda-forge's ctng-compiler-activation, which is the LINUX
# activation for both GCC and Clang - not clang-compiler-activation, which is
# macOS. Flag strings are lifted verbatim from its build_scripts.sh for
# linux-64. Cross-compilation, meson cross files, Darwin and Windows branches
# are all dropped: this package is linux-64 only.

_acpp_chost="x86_64-conda-linux-gnu"

# During a conda BUILD the toolchain is a build-platform tool while the headers
# and libraries it targets belong to the host prefix. A TEST has no build
# prefix, so both collapse to the host one. Outside a build there is only
# CONDA_PREFIX. Same three cases as the base script.
if [ "${CONDA_BUILD:-0}" = "1" ]; then
  if [ -n "${BUILD_PREFIX:-}" ]; then
    _acpp_tools="${BUILD_PREFIX}"
  else
    _acpp_tools="${PREFIX}"
  fi
  _acpp_target="${PREFIX}"
else
  _acpp_tools="${CONDA_PREFIX}"
  _acpp_target="${CONDA_PREFIX}"
fi

# ── flags ─────────────────────────────────────────────────────────────────
# -fno-merge-constants is absent on purpose: clang does not support it, which
# is exactly what ctng strips when deriving its clang scripts from the gcc ones.
_acpp_cppflags="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2 -isystem ${_acpp_target}/include"
_acpp_cflags="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${_acpp_target}/include"
_acpp_cxxflags="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${_acpp_target}/include"

_acpp_debug_cppflags="-D_DEBUG -D_FORTIFY_SOURCE=2 -Og -isystem ${_acpp_target}/include"
_acpp_debug_cflags="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -ffunction-sections -pipe -isystem ${_acpp_target}/include"
_acpp_debug_cxxflags="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -ffunction-sections -pipe -isystem ${_acpp_target}/include"

_acpp_ldflags="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined -Wl,-rpath,${_acpp_target}/lib -Wl,-rpath-link,${_acpp_target}/lib -L${_acpp_target}/lib"
_acpp_ldflags_ld="-O2 --sort-common --as-needed -z relro -z now --disable-new-dtags --gc-sections --allow-shlib-undefined -rpath ${_acpp_target}/lib -rpath-link ${_acpp_target}/lib -L${_acpp_target}/lib"

# ── cmake ─────────────────────────────────────────────────────────────────
# CMAKE_ARGS is NOT a cmake variable - cmake never reads it. It is a conda
# convention: a recipe must pass it on the command line itself. CC, CXX,
# CFLAGS, CXXFLAGS, LDFLAGS and CMAKE_PREFIX_PATH below ARE read by cmake
# directly, so those work whether or not a recipe cooperates.
_acpp_cmake_args="-DCMAKE_AR=${_acpp_tools}/bin/${_acpp_chost}-ar"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_CXX_COMPILER_AR=${_acpp_tools}/bin/${_acpp_chost}-ar"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_C_COMPILER_AR=${_acpp_tools}/bin/${_acpp_chost}-ar"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_RANLIB=${_acpp_tools}/bin/${_acpp_chost}-ranlib"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_CXX_COMPILER_RANLIB=${_acpp_tools}/bin/${_acpp_chost}-ranlib"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_C_COMPILER_RANLIB=${_acpp_tools}/bin/${_acpp_chost}-ranlib"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_LINKER=${_acpp_tools}/bin/${_acpp_chost}-ld"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_STRIP=${_acpp_tools}/bin/${_acpp_chost}-strip"
_acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_BUILD_TYPE=Release"

_acpp_meson_args="-Dbuildtype=release"

if [ "${CONDA_BUILD:-0}" = "1" ]; then
  _acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
  _acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_FIND_ROOT_PATH=${PREFIX};${_acpp_tools}/${_acpp_chost}/sysroot"
  _acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_INSTALL_LIBDIR=lib"
  _acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_PROGRAM_PATH=${_acpp_tools}/bin;${PREFIX}/bin"
  if [ -f "${PREFIX}/bin/python" ]; then
    # use the conda-forge python even if the system one is newer
    _acpp_cmake_args="${_acpp_cmake_args} -DCMAKE_POLICY_DEFAULT_CMP0094=NEW"
  fi
  _acpp_meson_args="${_acpp_meson_args} --prefix=${PREFIX} -Dlibdir=lib"
fi

_acpp_cmake_prefix_path="${_acpp_target}:${_acpp_target}/${_acpp_chost}/sysroot/usr"

# ── apply ─────────────────────────────────────────────────────────────────
# Every variable is backed up under CONDA_BACKUP_<NAME>, which is conda's own
# convention and what the deactivate script reverses.
_acpp_set() {
  _acpp_name="$1"
  _acpp_value="$2"
  eval "_acpp_old=\${${_acpp_name}:-}"
  if [ -n "${_acpp_old:-}" ]; then
    eval "export CONDA_BACKUP_${_acpp_name}=\"\${_acpp_old}\""
  else
    eval "unset CONDA_BACKUP_${_acpp_name}"
  fi
  eval "export ${_acpp_name}=\"\${_acpp_value}\""
}

_acpp_set HOST                   "${_acpp_chost}"
_acpp_set BUILD                  "${_acpp_chost}"
_acpp_set host_alias             "${_acpp_chost}"
_acpp_set build_alias            "${_acpp_chost}"
_acpp_set CONDA_TOOLCHAIN_HOST   "${_acpp_chost}"
_acpp_set CONDA_TOOLCHAIN_BUILD  "${_acpp_chost}"

_acpp_set CC                     "${_acpp_chost}-clang"
_acpp_set CXX                    "${_acpp_chost}-clang++"
_acpp_set CPP                    "${_acpp_chost}-clang-cpp"
_acpp_set CLANG                  "${_acpp_chost}-clang"
_acpp_set CLANGXX                "${_acpp_chost}-clang++"
_acpp_set CC_FOR_BUILD           "${_acpp_tools}/bin/${_acpp_chost}-clang"
_acpp_set CXX_FOR_BUILD          "${_acpp_tools}/bin/${_acpp_chost}-clang++"
_acpp_set CPP_FOR_BUILD          "${_acpp_tools}/bin/${_acpp_chost}-clang-cpp"

_acpp_set CPPFLAGS               "${_acpp_cppflags}"
_acpp_set CFLAGS                 "${_acpp_cflags}"
_acpp_set CXXFLAGS               "${_acpp_cxxflags}"
_acpp_set DEBUG_CPPFLAGS         "${_acpp_debug_cppflags}"
_acpp_set DEBUG_CFLAGS           "${_acpp_debug_cflags}"
_acpp_set DEBUG_CXXFLAGS         "${_acpp_debug_cxxflags}"
_acpp_set LDFLAGS                "${_acpp_ldflags}"
_acpp_set LDFLAGS_LD             "${_acpp_ldflags_ld}"

_acpp_set CMAKE_PREFIX_PATH      "${_acpp_cmake_prefix_path}"
_acpp_set CMAKE_ARGS             "${_acpp_cmake_args}"
_acpp_set MESON_ARGS             "${_acpp_meson_args}"
_acpp_set CONDA_BUILD_SYSROOT    "${_acpp_target}/${_acpp_chost}/sysroot"

# The whole point of this package: acpp compiles host code with the triplet
# driver, so its cfg file is consulted and the sysroot and include paths apply.
# The base package set this to a plain clang++; that value is already saved.
_acpp_set ACPP_CPU_CXX           "${_acpp_tools}/bin/${_acpp_chost}-clang++"

unset _acpp_chost _acpp_tools _acpp_target
unset _acpp_cppflags _acpp_cflags _acpp_cxxflags
unset _acpp_debug_cppflags _acpp_debug_cflags _acpp_debug_cxxflags
unset _acpp_ldflags _acpp_ldflags_ld
unset _acpp_cmake_args _acpp_meson_args _acpp_cmake_prefix_path
unset _acpp_name _acpp_value _acpp_old
