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

# ---- C side ----
_acpp_backup CC
_acpp_backup CFLAGS
_acpp_backup CPPFLAGS
_acpp_backup LDFLAGS
_acpp_backup DEBUG_CFLAGS
_acpp_backup CONDA_BUILD_SYSROOT
_acpp_backup AR
_acpp_backup NM
_acpp_backup RANLIB
_acpp_backup STRIP
_acpp_backup LD
_acpp_backup OBJCOPY
_acpp_backup OBJDUMP

export CC="${_ACPP_PFX}/bin/${_ACPP_CHOST}-clang"
export CFLAGS="${_ACPP_ARCH_FLAGS} ${_ACPP_SYSROOT_FLAGS} ${_ACPP_ISYSTEM}"
export CPPFLAGS="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2 ${_ACPP_ISYSTEM}"
export LDFLAGS="${_ACPP_LDFLAGS_VAL}"
export DEBUG_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra ${_ACPP_SYSROOT_FLAGS} ${_ACPP_ISYSTEM}"
export CONDA_BUILD_SYSROOT="${_ACPP_SYSROOT}"
export AR="${_ACPP_PFX}/bin/llvm-ar"
export NM="${_ACPP_PFX}/bin/llvm-nm"
export RANLIB="${_ACPP_PFX}/bin/llvm-ranlib"
export STRIP="${_ACPP_PFX}/bin/llvm-strip"
export LD="${_ACPP_PFX}/bin/ld.lld"
export OBJCOPY="${_ACPP_PFX}/bin/llvm-objcopy"
export OBJDUMP="${_ACPP_PFX}/bin/llvm-objdump"

# clang .cfg: applied on EVERY clang invocation (incl. acpp-internal ones),
# so --sysroot holds even without CFLAGS. Dynamic paths => written at
# activation, removed at deactivation.
printf '%s\n' "--target=${_ACPP_CHOST}" "--sysroot=${_ACPP_SYSROOT}" "-isystem ${_ACPP_PFX}/include" > "${_ACPP_PFX}/bin/clang.cfg"
cp "${_ACPP_PFX}/bin/clang.cfg" "${_ACPP_PFX}/bin/${_ACPP_CHOST}-clang.cfg"

_acpp_backup CMAKE_ARGS
export CMAKE_ARGS="${CMAKE_ARGS:-} -DCMAKE_C_COMPILER=${CC} -DCMAKE_AR=${AR} -DCMAKE_NM=${NM} -DCMAKE_RANLIB=${RANLIB} -DCMAKE_STRIP=${STRIP} -DCMAKE_LINKER=${LD} -DCMAKE_OBJCOPY=${OBJCOPY} -DCMAKE_OBJDUMP=${OBJDUMP} -DCMAKE_SYSROOT=${_ACPP_SYSROOT}"

unset _ACPP_PFX _ACPP_BUILD_MODE _ACPP_CHOST _ACPP_SYSROOT _ACPP_ARCH_FLAGS
unset _ACPP_SYSROOT_FLAGS _ACPP_ISYSTEM _ACPP_RPATH_PFX _ACPP_LDFLAGS_VAL
unset -f _acpp_backup
