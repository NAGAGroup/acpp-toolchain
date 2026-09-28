#!/bin/bash
# render-install-osx.sh — render + install the acpp compiler activation
# scripts from the VENDORED conda-forge clang-compiler-activation templates.
#
# Faithful port of the osx-arm64 NATIVE slice of the feedstock's build.sh +
# install-clang{,xx}.sh at the pinned ref recorded in
# vendor/clang-compiler-activation/PINNED_REF (this toolchain's only mac
# lane — no cross-compilation, no osx-64). Values below are quoted straight
# from vendor/clang-compiler-activation/{build.sh,conda_build_config.yaml}
# in the acpp-toolchain hand-off report. Everything is byte-identical to
# canonical rendering EXCEPT the block marked "ACPP DELTA".
#
# Usage: bash render-install-osx.sh {clang|clangxx}
# Expects: $PREFIX, $PKG_NAME (rattler-build env), vendored templates beside
# this script. Requires: bash, sed (build deps of the outputs).
set -euxo pipefail

side="${1:?usage: render-install-osx.sh clang|clangxx}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor="${here}/vendor/clang-compiler-activation"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp "${vendor}"/activate-clang.sh "${vendor}"/activate-clang++.sh \
   "${vendor}"/deactivate-clang.sh "${vendor}"/deactivate-clang++.sh "${work}/"
cd "${work}"

# ---- canonical values: osx-arm64 native (build.sh + conda_build_config) ----
CHOST=arm64-apple-darwin20.0.0     # macos_machine, zipped to cross_target_platform=osx-arm64
CBUILD=arm64-apple-darwin20.0.0    # build.sh's own target_platform==osx-arm64 branch (native: same as CHOST)

FINAL_CPPFLAGS="-D_FORTIFY_SOURCE=2 -DNDEBUG"   # DNDEBUG appended: our version (21.1.8) != "19.1.7"
# uname_machine=arm64 (not x86_64), so build.sh's x86_64-only "-march=core2
# -mtune=haswell -mssse3" prefix does NOT apply here.
FINAL_CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe"
FINAL_CXXFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -stdlib=libc++ -fvisibility-inlines-hidden -fmessage-length=0"
FINAL_LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
FINAL_LDFLAGS_LD="-headerpad_max_install_names -dead_strip_dylibs"
FINAL_DEBUG_CFLAGS="-Og -g -Wall -Wextra"
FINAL_DEBUG_CXXFLAGS="-Og -g -Wall -Wextra"

CONDA_BUILD_CROSS_COMPILATION=""   # native: target_platform == cross_target_platform
CC_FOR_BUILD="${CBUILD}-clang"
CPP_FOR_BUILD="${CBUILD}-clang-cpp"
CXX_FOR_BUILD="${CBUILD}-clang++"
UNAME_MACHINE="arm64"
MESON_CPU_FAMILY="aarch64"
UNAME_KERNEL_RELEASE="20.0.0"
TARGET_PLATFORM="osx-arm64"        # cross_target_platform
# Referenced by build.sh as ${FINAL_PYTHON_SYSCONFIGDATA_NAME} but never
# assigned there either — left empty, matching the feedstock's own
# effectively-unset behaviour (not needed for a plain C/C++ compile).
PYTHON_SYSCONFIGDATA_NAME=""

# ---- canonical @VAR@ substitution matrix (build.sh order) -------------------
subst() {
  find . -name "*activate*.sh" -not -name "*.bak" -exec sed -i.bak "s|$1|$2|g" "{}" \;
}
subst "@CHOST@" "${CHOST}"
subst "@CBUILD@" "${CBUILD}"
subst "@CPPFLAGS@" "${FINAL_CPPFLAGS}"
subst "@CC_FOR_BUILD@" "${CC_FOR_BUILD}"
subst "@CPP_FOR_BUILD@" "${CPP_FOR_BUILD}"
subst "@CXX_FOR_BUILD@" "${CXX_FOR_BUILD}"
subst "@CFLAGS@" "${FINAL_CFLAGS}"
subst "@DEBUG_CFLAGS@" "${FINAL_DEBUG_CFLAGS}"
subst "@CXXFLAGS@" "${FINAL_CXXFLAGS}"
subst "@DEBUG_CXXFLAGS@" "${FINAL_DEBUG_CXXFLAGS}"
subst "@LDFLAGS@" "${FINAL_LDFLAGS}"
subst "@LDFLAGS_LD@" "${FINAL_LDFLAGS_LD}"
subst "@CONDA_BUILD_CROSS_COMPILATION@" "${CONDA_BUILD_CROSS_COMPILATION}"
subst "@_PYTHON_SYSCONFIGDATA_NAME@" "${PYTHON_SYSCONFIGDATA_NAME}"
subst "@UNAME_MACHINE@" "${UNAME_MACHINE}"
subst "@MESON_CPU_FAMILY@" "${MESON_CPU_FAMILY}"
subst "@UNAME_KERNEL_RELEASE@" "${UNAME_KERNEL_RELEASE}"
subst "@TARGET_PLATFORM@" "${TARGET_PLATFORM}"
find . -name "*activate*.sh.bak" -exec rm "{}" \;

# ---- ACPP DELTA: SYCL environment on the CXX side ---------------------------
# ACPP_TARGETS respects a pre-set value (generic SSCP is the only compiled
# flow); ACPP_CLANG/ACPP_CPU_CXX point the fork's CPU JIT driver at this
# activation's own clang++. Appended as two more args to each script's
# EXISTING _tc_activation call (not a second call), so the same
# CONDA_BACKUP_-based restore-on-deactivate mechanism covers them — the
# anchor line is the last arg of the canonical call, unique to the clang++
# scripts.
sed -i.bak \
  's|"DEBUG_CXXFLAGS,\${DEBUG_CXXFLAGS:-\${DEBUG_CXXFLAGS_USED}}"|& \\\n  "ACPP_TARGETS,\${ACPP_TARGETS:-generic}" \\\n  "ACPP_CLANG,\${CONDA_PREFIX}/bin/'"${CHOST}"'-clang++" \\\n  "ACPP_CPU_CXX,\${CONDA_PREFIX}/bin/'"${CHOST}"'-clang++"|' \
  activate-clang++.sh deactivate-clang++.sh
rm -f activate-clang++.sh.bak deactivate-clang++.sh.bak

# ---- install (PKG_NAME naming, matching render-install.sh's convention) ----
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
