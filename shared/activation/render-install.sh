#!/bin/bash
# render-install.sh — render + install the acpp compiler activation scripts
# from the VENDORED conda-forge ctng-compiler-activation templates.
#
# Faithful port of the linux-64-native slice of the feedstock's
# build_scripts.sh + install-clang{,++}.sh at the pinned ref recorded in
# vendor/ctng-compiler-activation/PINNED_REF. Everything is byte-identical to
# canonical rendering EXCEPT sections marked "ACPP DELTA". Design v3 §D2.
#
# Usage: bash render-install.sh {clang|clangxx}
# Expects: $PREFIX, $PKG_NAME (rattler-build env), vendored templates beside
# this script. Requires: bash, sed, shellcheck (build deps of the outputs).
set -euxo pipefail

side="${1:?usage: render-install.sh clang|clangxx}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor="${here}/vendor/ctng-compiler-activation"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp "${vendor}"/activate-gcc.sh "${vendor}"/activate-g++.sh \
   "${vendor}"/deactivate-gcc.sh "${vendor}"/deactivate-g++.sh "${work}/"
cd "${work}"

# ---- canonical values: linux-64 native (build_scripts.sh) -------------------
CHOST=x86_64-conda-linux-gnu
CBUILD=x86_64-conda-linux-gnu

FINAL_CPPFLAGS="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2"
FINAL_DEBUG_CPPFLAGS="-D_DEBUG -D_FORTIFY_SOURCE=2 -Og"
FINAL_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
# -std=c++17 stripped: canonical strips it for toolchain majors >= 11
FINAL_CXXFLAGS="-fvisibility-inlines-hidden -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
FINAL_LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_LD="-O2 --sort-common --as-needed -z relro -z now --disable-new-dtags --gc-sections --allow-shlib-undefined"
FINAL_DEBUG_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -ffunction-sections -pipe"
FINAL_DEBUG_CXXFLAGS="-fvisibility-inlines-hidden -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -ffunction-sections -pipe"

CONDA_BUILD_CROSS_COMPILATION=""   # native
CMAKE_SYSTEM_NAME="Linux"
MESON_SYSTEM="linux"
MACHINE="x86_64"
MESON_FAMILY="x86_64"
uname_kernel_release=0
IS_WIN=0
EXE_EXT=""
LIBRARY_PREFIX=""

# ---- canonical @VAR@ substitution matrix (build_scripts.sh order) -----------
subst() {
  find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|$1|$2|g" "{}" \;
}
subst "@UNAME_KERNEL_RELEASE@" "${uname_kernel_release}"
subst "@IS_WIN@" "${IS_WIN}"
subst "@MACHINE@" "${MACHINE}"
subst "@CMAKE_SYSTEM_NAME@" "${CMAKE_SYSTEM_NAME}"
subst "@MESON_SYSTEM@" "${MESON_SYSTEM}"
subst "@MESON_FAMILY@" "${MESON_FAMILY}"
subst "@CBUILD@" "${CBUILD}"
subst "@CHOST@" "${CHOST}"
subst "@CPPFLAGS@" "${FINAL_CPPFLAGS}"
subst "@DEBUG_CPPFLAGS@" "${FINAL_DEBUG_CPPFLAGS}"
subst "@CFLAGS@" "${FINAL_CFLAGS}"
subst "@DEBUG_CFLAGS@" "${FINAL_DEBUG_CFLAGS}"
subst "@CXXFLAGS@" "${FINAL_CXXFLAGS}"
subst "@DEBUG_CXXFLAGS@" "${FINAL_DEBUG_CXXFLAGS}"
subst "@LDFLAGS@" "${FINAL_LDFLAGS}"
subst "@LDFLAGS_LD@" "${FINAL_LDFLAGS_LD}"
subst "@EXE_EXT@" "${EXE_EXT}"
subst "@LIBRARY_PREFIX@" "${LIBRARY_PREFIX}"
subst "@CONDA_BUILD_CROSS_COMPILATION@" "${CONDA_BUILD_CROSS_COMPILATION}"

# ---- clang variants (canonical: cp + -fno-merge-constants removal) ----------
cp activate-gcc.sh activate-clang.sh
cp activate-g++.sh activate-clang++.sh
cp deactivate-gcc.sh deactivate-clang.sh
cp deactivate-g++.sh deactivate-clang++.sh
sed -i.bak "s| -fno-merge-constants||g" activate-clang.sh activate-clang++.sh

# ---- compiler-specific _tc_activation entries -------------------------------
# Canonical CLANG_EXTRA / CLANGXX_EXTRA verbatim…
CLANG_EXTRA=" \
\"CC,${CHOST}-clang\" \
\"CPP,${CHOST}-clang-cpp\" \
\"OBJC,${CHOST}-clang\" \
\"CC_FOR_BUILD,${CBUILD}-clang\" \
\"CPP_FOR_BUILD,${CBUILD}-clang-cpp\" \
\"OBJC_FOR_BUILD,${CBUILD}-clang\" \
\"CLANG,${CHOST}-clang\" \
\"ac_cv_func_malloc_0_nonnull,yes\" \
\"ac_cv_func_realloc_0_nonnull,yes\" \
"
CLANGXX_EXTRA=" \
\"CXX,${CHOST}-clang++\" \
\"OBJCXX,${CHOST}-clang++\" \
\"CXX_FOR_BUILD,${CBUILD}-clang++\" \
\"OBJCXX_FOR_BUILD,${CBUILD}-clang++\" \
\"CLANGXX,${CHOST}-clang++\" \
"
# …ACPP DELTA: SYCL environment on the CXX side. Values with \${...} expand at
# activation time; ACPP_TARGETS respects a pre-set value (generic SSCP is the
# only compiled flow — one binary, JIT per device). AdaptiveCpp's CMake config
# is found through the canonical CMAKE_PREFIX_PATH — no AdaptiveCpp_DIR needed.
CLANGXX_EXTRA="${CLANGXX_EXTRA} \
\"ACPP_TARGETS,\${ACPP_TARGETS:-generic}\" \
\"ACPP_COMPILER_DIR,\${CONDA_PREFIX}\" \
\"ACPP_CLANG,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
\"ACPP_CPU_CXX,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
"

find . -name "*activate-clang.sh" -exec sed -i.bak "s|@C_EXTRA@|${CLANG_EXTRA}|g" "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@AR@|${CHOST}-ar|g" "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@NM@|${CHOST}-nm|g" "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@RANLIB@|${CHOST}-ranlib|g" "{}" \;
find . -name "*activate-clang++.sh" -exec sed -i.bak "s|@CXX_EXTRA@|${CLANGXX_EXTRA}|g" "{}" \;
find . -name "*activate*.sh.bak" -exec rm "{}" \;

# ---- canonical shellcheck gate ----------------------------------------------
errors=$(find . -name "*activate*.sh" -exec shellcheck -e SC3043 -e SC2050 --severity=info --format=gcc {} \;)
echo "${errors}"
if [[ ${errors} != "" ]]; then
  exit 1
fi

# ---- install (canonical install-clang{,++}.sh, PKG_NAME naming) -------------
# The triple-prefixed driver names install HERE, not in the base packages:
# conda-forge's clangxx ships clang++, clangxx_linux-64 ships the triplet.
# The triplet's presence is what tells the ecosystem (and clang's own
# argv[0] handling) that it is in an isolated conda build env, so a base
# package carrying it poisons plain runtime environments.
mkdir -p "${PREFIX}/etc/conda/activate.d" "${PREFIX}/etc/conda/deactivate.d" "${PREFIX}/bin"
case "${side}" in
  clang)
    cp activate-clang.sh   "${PREFIX}/etc/conda/activate.d/activate-${PKG_NAME}.sh"
    cp deactivate-clang.sh "${PREFIX}/etc/conda/deactivate.d/deactivate-${PKG_NAME}.sh"
    ln -sf clang     "${PREFIX}/bin/${CHOST}-clang"
    ln -sf clang-cpp "${PREFIX}/bin/${CHOST}-clang-cpp"
    ;;
  clangxx)
    cp activate-clang++.sh   "${PREFIX}/etc/conda/activate.d/activate-${PKG_NAME}.sh"
    cp deactivate-clang++.sh "${PREFIX}/etc/conda/deactivate.d/deactivate-${PKG_NAME}.sh"
    ln -sf clang++ "${PREFIX}/bin/${CHOST}-clang++"
    ;;
  *) echo "unknown side: ${side}"; exit 1 ;;
esac
