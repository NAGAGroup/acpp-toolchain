#!/bin/bash
# build.sh — render the activation scripts from the templates in this
# directory. SOURCED by install-clang.sh and install-clangxx.sh rather than run
# as a top-level build script: rattler-build has no build step shared across
# outputs, so each output renders what it is about to install.
#
# Output lands in ${SRC_DIR}/rendered, never in place, so the templates stay
# readable next to the rendered result.

set -e -x

: "${CHOST:?CHOST must be set by the recipe}"
: "${LLVM_MAJOR:?LLVM_MAJOR must be set by the recipe}"

# Native build: the host triple IS the build triple. Upstream derives CBUILD
# from target_platform through a four-way branch because it also cross-compiles
# from linux; we build osx-arm64 on osx-arm64.
CBUILD=${CHOST}
CONDA_BUILD_CROSS_COMPILATION=""

# -DNDEBUG is unconditional. Upstream gates it on `version != "19.1.7"`, a
# version comparison, and this lane's PKG_VERSION is a date.
FINAL_CPPFLAGS="-D_FORTIFY_SOURCE=2 -DNDEBUG"

# arm64 only. Upstream's -march=core2 -mtune=haswell -mssse3 block applies to
# osx-64, a platform this fork does not build.
FINAL_CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe"
FINAL_CXXFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -stdlib=libc++ -fvisibility-inlines-hidden -fmessage-length=0"

# LDFLAGS for a compiler driving the linker, and for calling the linker direct.
FINAL_LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
FINAL_LDFLAGS_LD="-headerpad_max_install_names -dead_strip_dylibs"
FINAL_DEBUG_CFLAGS="-Og -g -Wall -Wextra"
FINAL_DEBUG_CXXFLAGS="-Og -g -Wall -Wextra"

CC_FOR_BUILD=${CBUILD}-clang
CPP_FOR_BUILD=${CBUILD}-clang-cpp
CXX_FOR_BUILD=${CBUILD}-clang++

# The SYCL half of the contract, on the C++ side. Values written as \${...}
# expand at activation time, not here. ACPP_TARGETS respects a value the user
# already set; generic SSCP is the only compiled flow, so the default is one
# binary that JITs per device. AdaptiveCpp's CMake package is found through the
# CMAKE_PREFIX_PATH the C script exports, so no AdaptiveCpp_DIR is needed.
ACPP_EXTRA=" \
\"ACPP_TARGETS,\${ACPP_TARGETS:-generic}\" \
\"ACPP_COMPILER_DIR,\${CONDA_PREFIX}\" \
\"ACPP_CLANG,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
\"ACPP_CPU_CXX,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
"
# On deactivation the helper restores each name from CONDA_BACKUP_, so only the
# names matter.
ACPP_EXTRA_DEACTIVATE=" \
\"ACPP_TARGETS,\" \
\"ACPP_COMPILER_DIR,\" \
\"ACPP_CLANG,\" \
\"ACPP_CPU_CXX,\" \
"

_ACPP_RENDER_DIR="${SRC_DIR}/rendered"
rm -rf "${_ACPP_RENDER_DIR}"
mkdir -p "${_ACPP_RENDER_DIR}"
find "${RECIPE_DIR}" -maxdepth 1 -name "*activate*.sh" -exec cp {} "${_ACPP_RENDER_DIR}"/ \;

pushd "${_ACPP_RENDER_DIR}"
  for f in *activate*.sh; do
    sed -i.bak "s|@CHOST@|${CHOST}|g"                                     "${f}"
    sed -i.bak "s|@CBUILD@|${CBUILD}|g"                                   "${f}"
    sed -i.bak "s|@CPPFLAGS@|${FINAL_CPPFLAGS}|g"                         "${f}"
    sed -i.bak "s|@CC_FOR_BUILD@|${CC_FOR_BUILD}|g"                       "${f}"
    # Upstream never substitutes this one, so its deactivate script ships the
    # literal token. OBJC and CC are the same driver.
    sed -i.bak "s|@OBJC_FOR_BUILD@|${CC_FOR_BUILD}|g"                     "${f}"
    sed -i.bak "s|@CPP_FOR_BUILD@|${CPP_FOR_BUILD}|g"                     "${f}"
    sed -i.bak "s|@CXX_FOR_BUILD@|${CXX_FOR_BUILD}|g"                     "${f}"
    sed -i.bak "s|@CFLAGS@|${FINAL_CFLAGS}|g"                             "${f}"
    sed -i.bak "s|@DEBUG_CFLAGS@|${FINAL_DEBUG_CFLAGS}|g"                 "${f}"
    sed -i.bak "s|@CXXFLAGS@|${FINAL_CXXFLAGS}|g"                         "${f}"
    sed -i.bak "s|@DEBUG_CXXFLAGS@|${FINAL_DEBUG_CXXFLAGS}|g"             "${f}"
    sed -i.bak "s|@LDFLAGS@|${FINAL_LDFLAGS}|g"                           "${f}"
    sed -i.bak "s|@LDFLAGS_LD@|${FINAL_LDFLAGS_LD}|g"                     "${f}"
    sed -i.bak "s|@CONDA_BUILD_CROSS_COMPILATION@|${CONDA_BUILD_CROSS_COMPILATION}|g" "${f}"
    sed -i.bak "s|@_PYTHON_SYSCONFIGDATA_NAME@||g"                        "${f}"
    sed -i.bak "s|@UNAME_MACHINE@|${UNAME_MACHINE}|g"                     "${f}"
    sed -i.bak "s|@MESON_CPU_FAMILY@|${MESON_CPU_FAMILY}|g"               "${f}"
    sed -i.bak "s|@UNAME_KERNEL_RELEASE@|${UNAME_KERNEL_RELEASE}|g"       "${f}"
    sed -i.bak "s|@TARGET_PLATFORM@|${cross_target_platform}|g"           "${f}"
  done

  sed -i.bak "s|@ACPP_EXTRA@|${ACPP_EXTRA}|g"            activate-clang++.sh
  sed -i.bak "s|@ACPP_EXTRA@|${ACPP_EXTRA_DEACTIVATE}|g" deactivate-clang++.sh

  rm -f ./*.bak

  # Nothing may survive unrendered: an unsubstituted token in a shipped script
  # is a broken flag or a bogus path in a consumer's environment, and it looks
  # fine in the artifact.
  if grep -nE '@[A-Z_][A-Z_]*@' ./*.sh; then
    echo "ERROR: unsubstituted @TOKEN@ left in a rendered activation script"
    exit 1
  fi
popd
