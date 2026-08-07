#!/usr/bin/env bash
# Sourced on `conda activate` / `pixi run`. Part of the acpp compiler
# activation family (CC side: acpp-clang_linux-64; CXX side:
# acpp-clangxx_linux-64) — each package only touches its own variables so
# mixed-compiler environments (e.g. c_compiler=gcc + cxx_compiler=
# acpp-clangxx) stay coherent, mirroring conda-forge's gcc/gxx/clang/
# clangxx split.

_acpp_backup() {
    local var="$1"; local bak="CONDA_BACKUP_ACPP_${var}"
    if [ -n "${!var+x}" ]; then export "${bak}=${!var}"; else export "${bak}=__CONDA_ACPP_UNSET__"; fi
}

if [ -n "${SRC_DIR:-}" ] && [ -n "${PKG_NAME:-}" ]; then
    _ACPP_PFX="${PREFIX}"; _ACPP_BUILD_MODE=1
else
    _ACPP_PFX="${CONDA_PREFIX}"; _ACPP_BUILD_MODE=0
fi
_ACPP_CHOST="x86_64-conda-linux-gnu"
_ACPP_SYSROOT="${_ACPP_PFX}/${_ACPP_CHOST}/sysroot"

if [ ! -d "${_ACPP_SYSROOT}/usr/include" ]; then
    echo "WARNING [acpp activation]: sysroot not found at ${_ACPP_SYSROOT} (need sysroot_linux-64 >=2.28)" >&2
fi

# conda-forge-style hardened flag sets (linux-64)
_ACPP_ARCH_FLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
_ACPP_SYSROOT_FLAGS="--sysroot=${_ACPP_SYSROOT} --target=${_ACPP_CHOST}"
if [ "${_ACPP_BUILD_MODE}" -eq 1 ]; then
    _ACPP_ISYSTEM="-isystem ${PREFIX}/include -fdebug-prefix-map=${SRC_DIR}=/usr/local/src/conda/${PKG_NAME}-${PKG_VERSION} -fdebug-prefix-map=${PREFIX}=/usr/local/src/conda-prefix"
    _ACPP_RPATH_PFX="${PREFIX}"
else
    _ACPP_ISYSTEM="-isystem ${CONDA_PREFIX}/include"
    _ACPP_RPATH_PFX="${CONDA_PREFIX}"
fi
_ACPP_LDFLAGS_VAL="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined --sysroot=${_ACPP_SYSROOT} -Wl,-rpath,${_ACPP_RPATH_PFX}/lib -Wl,-rpath-link,${_ACPP_RPATH_PFX}/lib -L${_ACPP_RPATH_PFX}/lib -fuse-ld=lld"

# ---- C++ side ----
_acpp_backup CXX
_acpp_backup CXXFLAGS
_acpp_backup DEBUG_CXXFLAGS
_acpp_backup ACPP_TARGETS
_acpp_backup ACPP_COMPILER_DIR
_acpp_backup ACPP_CLANG

export CXX="${_ACPP_PFX}/bin/${_ACPP_CHOST}-clang++"
export CXXFLAGS="${_ACPP_ARCH_FLAGS} -fvisibility-inlines-hidden -fmessage-length=0 ${_ACPP_SYSROOT_FLAGS} ${_ACPP_ISYSTEM}"
export DEBUG_CXXFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvisibility-inlines-hidden -fmessage-length=0 ${_ACPP_SYSROOT_FLAGS} ${_ACPP_ISYSTEM}"

# generic SSCP is the only compiled flow — one binary, JIT per device
if [ -z "${ACPP_TARGETS:-}" ]; then export ACPP_TARGETS="generic"; fi
export ACPP_COMPILER_DIR="${_ACPP_PFX}"
export ACPP_CLANG="${_ACPP_PFX}/bin/clang++"

# C++ stdlib include paths come from libstdcxx-devel via the gcc tree
_ACPP_GXX_INC="${_ACPP_PFX}/${_ACPP_CHOST}/include/c++"
_ACPP_GXX_VER="$(ls "${_ACPP_GXX_INC}" 2>/dev/null | head -1)"
printf '%s\n' "--target=${_ACPP_CHOST}" "--sysroot=${_ACPP_SYSROOT}" "-isystem ${_ACPP_PFX}/include" "-isystem ${_ACPP_GXX_INC}/${_ACPP_GXX_VER}" "-isystem ${_ACPP_GXX_INC}/${_ACPP_GXX_VER}/${_ACPP_CHOST}" > "${_ACPP_PFX}/bin/clang++.cfg"
cp "${_ACPP_PFX}/bin/clang++.cfg" "${_ACPP_PFX}/bin/${_ACPP_CHOST}-clang++.cfg"
unset _ACPP_GXX_INC _ACPP_GXX_VER

_acpp_backup CMAKE_ARGS
export CMAKE_ARGS="${CMAKE_ARGS:-} -DCMAKE_CXX_COMPILER=${CXX} -DAdaptiveCpp_DIR=${_ACPP_PFX}/lib/cmake/AdaptiveCpp"

unset _ACPP_PFX _ACPP_BUILD_MODE _ACPP_CHOST _ACPP_SYSROOT _ACPP_ARCH_FLAGS
unset _ACPP_SYSROOT_FLAGS _ACPP_ISYSTEM _ACPP_RPATH_PFX _ACPP_LDFLAGS_VAL
unset -f _acpp_backup
