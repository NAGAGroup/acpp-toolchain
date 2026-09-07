#!/bin/bash

set -exu

# Generates the activation scripts the acpp-clang_* packages ship. The clang
# scripts do not exist in the tree: they are the gcc ones with
# -fno-merge-constants removed and a clang-specific @C_EXTRA@ block
# substituted in. Only the clang pair is generated here — the gcc, g++ and
# gfortran outputs this feedstock also carries upstream are not built.

source $RECIPE_DIR/get_cpu_arch.sh

FINAL_CPPFLAGS="-DNDEBUG -D_FORTIFY_SOURCE=2 -O2"

FINAL_CFLAGS_linux_64="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
FINAL_CFLAGS_linux_ppc64le="-mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CFLAGS_linux_aarch64="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CFLAGS_linux_s390x="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CFLAGS_linux_riscv64="-march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CFLAGS_win_64="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CFLAGS_osx_64="-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe"
FINAL_CFLAGS_osx_arm64="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe"

FINAL_CXXFLAGS_linux_64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
FINAL_CXXFLAGS_linux_ppc64le="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CXXFLAGS_linux_aarch64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CXXFLAGS_linux_s390x="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CXXFLAGS_linux_riscv64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CXXFLAGS_win_64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_CXXFLAGS_osx_64="-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -stdlib=libc++ -fvisibility-inlines-hidden -fmessage-length=0"
FINAL_CXXFLAGS_osx_arm64="-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -stdlib=libc++ -fvisibility-inlines-hidden -fmessage-length=0"

FINAL_FFLAGS_linux_64="-fopenmp -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
FINAL_FFLAGS_linux_ppc64le="-fopenmp -mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_FFLAGS_linux_aarch64="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_FFLAGS_linux_s390x="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_FFLAGS_linux_riscv64="-fopenmp -march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_FFLAGS_win_64="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe"
FINAL_FFLAGS_osx_64="-march=core2 -mtune=haswell -ftree-vectorize -fPIC -fstack-protector -O2 -pipe"
FINAL_FFLAGS_osx_arm64="-march=armv8.3-a -ftree-vectorize -fPIC -fno-stack-protector -O2 -pipe"

FINAL_LDFLAGS_linux_64="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_linux_ppc64le="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_linux_aarch64="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_linux_s390x="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_linux_riscv64="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined"
FINAL_LDFLAGS_win_64="-Wl,-O2 -Wl,--sort-common"
FINAL_LDFLAGS_osx_64="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
FINAL_LDFLAGS_osx_arm64="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"

FINAL_LDFLAGS_LD_linux_64="-O2 --sort-common --as-needed -z relro -z now --disable-new-dtags --gc-sections --allow-shlib-undefined"
FINAL_LDFLAGS_LD_linux_ppc64le="-O2 --sort-common --as-needed -z relro -z now --allow-shlib-undefined"
FINAL_LDFLAGS_LD_linux_aarch64="-O2 --sort-common --as-needed -z relro -z now --allow-shlib-undefined"
FINAL_LDFLAGS_LD_linux_s390x="-O2 --sort-common --as-needed -z relro -z now --allow-shlib-undefined"
FINAL_LDFLAGS_LD_linux_riscv64="-O2 --sort-common --as-needed -z relro -z now --allow-shlib-undefined"
FINAL_LDFLAGS_LD_win_64="-O2 --sort-common"
FINAL_LDFLAGS_LD_osx_64="-headerpad_max_install_names -dead_strip_dylibs"
FINAL_LDFLAGS_LD_osx_arm64="-headerpad_max_install_names -dead_strip_dylibs"

FINAL_DEBUG_CPPFLAGS="-D_DEBUG -D_FORTIFY_SOURCE=2 -Og"

FINAL_DEBUG_CFLAGS_linux_64="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -ffunction-sections -pipe"
FINAL_DEBUG_CFLAGS_linux_ppc64le="-mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CFLAGS_linux_aarch64="-ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CFLAGS_linux_s390x="-ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CFLAGS_linux_riscv64="-march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CFLAGS_win_64="-ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CFLAGS_osx_64="-Og -g -Wall -Wextra"
FINAL_DEBUG_CFLAGS_osx_arm64="-Og -g -Wall -Wextra"

FINAL_DEBUG_CXXFLAGS_linux_64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -ffunction-sections -pipe"
FINAL_DEBUG_CXXFLAGS_linux_ppc64le="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CXXFLAGS_linux_aarch64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CXXFLAGS_linux_s390x="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CXXFLAGS_linux_riscv64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CXXFLAGS_win_64="-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fvar-tracking-assignments -pipe"
FINAL_DEBUG_CXXFLAGS_osx_64="-Og -g -Wall -Wextra"
FINAL_DEBUG_CXXFLAGS_osx_arm64="-Og -g -Wall -Wextra"

FINAL_DEBUG_FFLAGS_linux_64="-fopenmp -march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-all -fno-plt -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fimplicit-none -fvar-tracking-assignments -ffunction-sections -pipe"
FINAL_DEBUG_FFLAGS_linux_ppc64le="-fopenmp -mcpu=power8 -mtune=power8 -ftree-vectorize -fPIC -fstack-protector-strong -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fvar-tracking-assignments -pipe"
FINAL_DEBUG_FFLAGS_linux_aarch64="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fvar-tracking-assignments -pipe"
FINAL_DEBUG_FFLAGS_linux_s390x="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fvar-tracking-assignments -pipe"
FINAL_DEBUG_FFLAGS_linux_riscv64="-fopenmp -march=rv64imafdc -mabi=lp64d -ftree-vectorize -fPIC -fstack-protector-strong -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fvar-tracking-assignments -pipe"
FINAL_DEBUG_FFLAGS_win_64="-fopenmp -ftree-vectorize -fPIC -fstack-protector-strong -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fvar-tracking-assignments -pipe"
FINAL_DEBUG_FFLAGS_osx_64="-march=core2 -mtune=haswell -ftree-vectorize -fPIC -fstack-protector -O2 -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fimplicit-none -fvar-tracking-assignments"
FINAL_DEBUG_FFLAGS_osx_arm64="-march=armv8.3-a -ftree-vectorize -fPIC -fno-stack-protector -O2 -pipe -Og -g -Wall -Wextra -fcheck=all -fbacktrace -fimplicit-none -fvar-tracking-assignments"

cross_target_platform_u=${cross_target_platform/-/_}

FINAL_CFLAGS=FINAL_CFLAGS_${cross_target_platform_u}
FINAL_DEBUG_CFLAGS=FINAL_DEBUG_CFLAGS_${cross_target_platform_u}
FINAL_CXXFLAGS=FINAL_CXXFLAGS_${cross_target_platform_u}
FINAL_DEBUG_CXXFLAGS=FINAL_DEBUG_CXXFLAGS_${cross_target_platform_u}
FINAL_FFLAGS=FINAL_FFLAGS_${cross_target_platform_u}
FINAL_DEBUG_FFLAGS=FINAL_DEBUG_FFLAGS_${cross_target_platform_u}
FINAL_LDFLAGS=FINAL_LDFLAGS_${cross_target_platform_u}
FINAL_LDFLAGS_LD=FINAL_LDFLAGS_LD_${cross_target_platform_u}

echo "FINAL_CFLAGS_linux_64: ${FINAL_CFLAGS_linux_64}"

FINAL_CFLAGS="${!FINAL_CFLAGS}"
echo "$FINAL_CFLAGS"
FINAL_CXXFLAGS="${!FINAL_CXXFLAGS}"
FINAL_FFLAGS="${!FINAL_FFLAGS}"
FINAL_DEBUG_CFLAGS="${!FINAL_DEBUG_CFLAGS}"
FINAL_DEBUG_CXXFLAGS="${!FINAL_DEBUG_CXXFLAGS}"
FINAL_DEBUG_FFLAGS="${!FINAL_DEBUG_FFLAGS}"
FINAL_LDFLAGS="${!FINAL_LDFLAGS}"
FINAL_LDFLAGS_LD="${!FINAL_LDFLAGS_LD}"

# -std=c++17 is not a default flag. Upstream keeps it for gcc 8/9/10, where
# some package ABIs (boost among them) change with the C++ standard, and
# strips it above that; the clang this activates is well past that boundary,
# so the strip is unconditional. See
# https://github.com/conda-forge/ctng-compiler-activation-feedstock/issues/42
FINAL_CXXFLAGS="$(echo $FINAL_CXXFLAGS | sed 's/-std=c++17 //g')"
FINAL_DEBUG_CXXFLAGS="$(echo $FINAL_DEBUG_CXXFLAGS | sed 's/-std=c++17 //g')"

if [ -z "${FINAL_CFLAGS}" ]; then
    echo "FINAL_CFLAGS not set.  Did you pass in a flags variant config file?"
    exit 1
fi

if [[ "$target_platform" == "$cross_target_platform" ]]; then
  export CONDA_BUILD_CROSS_COMPILATION=""
else
  export CONDA_BUILD_CROSS_COMPILATION="1"
fi

if [[ "$target_platform" == "win-"* ]]; then
  IS_WIN=1
else
  IS_WIN=0
fi


if [[ "${cross_target_platform}" == "linux-"* ]]; then
  CMAKE_SYSTEM_NAME="Linux"
elif [[ "${cross_target_platform}" == "win-"* ]]; then
  CMAKE_SYSTEM_NAME="Windows"
else
  CMAKE_SYSTEM_NAME="Darwin"
fi

MESON_SYSTEM=$(echo "$CMAKE_SYSTEM_NAME" | tr '[:upper:]' '[:lower:]')

if [[ "${target_platform}" == "win-"* ]]; then
  LIBRARY_PREFIX="/Library"
  EXE_EXT=".exe"
else
  LIBRARY_PREFIX=""
  EXE_EXT=""
fi

MACHINE=$(echo ${CHOST} | cut -d "-" -f1)
MESON_FAMILY=${MACHINE}

if [[ "$cross_target_platform" == linux-ppc64le ]]; then
  MACHINE="ppc64le"
  MESON_FAMILY="ppc64"
fi

if [[ "${cross_target_platform}" == "osx-64" ]]; then
  uname_kernel_release=13.4.0
elif [[ "${cross_target_platform}" == "osx-arm64" ]]; then
  uname_kernel_release=20.0.0
else
  uname_kernel_release=0
fi

find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@UNAME_KERNEL_RELEASE@|${uname_kernel_release}|g"                      "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@IS_WIN@|${IS_WIN}|g"                                                  "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@MACHINE@|${MACHINE}|g"                                                "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CMAKE_SYSTEM_NAME@|${CMAKE_SYSTEM_NAME}|g"                            "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@MESON_SYSTEM@|${MESON_SYSTEM}|g"                                      "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@MESON_FAMILY@|${MESON_FAMILY}|g"                                      "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CBUILD@|${CBUILD}|g"                                                  "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CHOST@|${CHOST}|g"                                                    "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CPPFLAGS@|${FINAL_CPPFLAGS}|g"                                        "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@DEBUG_CPPFLAGS@|${FINAL_DEBUG_CPPFLAGS}|g"                            "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CFLAGS@|${FINAL_CFLAGS}|g"                                            "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@DEBUG_CFLAGS@|${FINAL_DEBUG_CFLAGS}|g"                                "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CXXFLAGS@|${FINAL_CXXFLAGS}|g"                                        "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@DEBUG_CXXFLAGS@|${FINAL_DEBUG_CXXFLAGS}|g"                            "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@FFLAGS@|${FINAL_FFLAGS}|g"                                            "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@DEBUG_FFLAGS@|${FINAL_DEBUG_FFLAGS}|g"                                "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@LDFLAGS@|${FINAL_LDFLAGS}|g"                                          "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@LDFLAGS_LD@|${FINAL_LDFLAGS_LD}|g"                                    "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@EXE_EXT@|${EXE_EXT}|g"                                                "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@LIBRARY_PREFIX@|${LIBRARY_PREFIX}|g"                                  "{}" \;
find . -name "*activate*.*" -not -name "*.bak" -exec sed -i.bak "s|@CONDA_BUILD_CROSS_COMPILATION@|${CONDA_BUILD_CROSS_COMPILATION}|g"    "{}" \;

cp activate-gcc.sh activate-clang.sh
cp activate-g++.sh activate-clang++.sh
cp deactivate-gcc.sh deactivate-clang.sh
cp deactivate-g++.sh deactivate-clang++.sh

# clang does not support -fno-merge-constants (and does not perform the
# problematic optimisation, see issue #63)
sed -i.bak "s| -fno-merge-constants||g" activate-clang.sh activate-clang++.sh

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
# The SYCL half of the contract, on the C++ side. Values written as \${...}
# expand at activation time, not here. ACPP_TARGETS respects a value the user
# already set; generic SSCP is the only compiled flow, so the default is one
# binary that JITs per device. AdaptiveCpp's CMake package is found through
# the CMAKE_PREFIX_PATH the C script exports, so no AdaptiveCpp_DIR is needed.
CLANGXX_EXTRA="${CLANGXX_EXTRA} \
\"ACPP_TARGETS,\${ACPP_TARGETS:-generic}\" \
\"ACPP_COMPILER_DIR,\${CONDA_PREFIX}\" \
\"ACPP_CLANG,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
\"ACPP_CPU_CXX,\${CONDA_PREFIX}/bin/${CHOST}-clang++\" \
"

find . -name "*activate-clang.sh" -exec sed -i.bak "s|@C_EXTRA@|${CLANG_EXTRA}|g"                       "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@AR@|${CHOST}-ar|g"                               "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@NM@|${CHOST}-nm|g"                               "{}" \;
find . -name "*activate-clang.sh" -exec sed -i.bak "s|@RANLIB@|${CHOST}-ranlib|g"                       "{}" \;
find . -name "*activate-clang++.sh" -exec sed -i.bak "s|@CXX_EXTRA@|${CLANGXX_EXTRA}|g"                 "{}" \;

find . -name "*activate*.sh.bak" -exec rm "{}" \;

# The gcc, g++ and gfortran templates are inputs to the generation above, not
# products of it: their @C_EXTRA@/@CXX_EXTRA@ tokens are never substituted
# because those outputs are not built here. Remove them so the gate below
# inspects exactly the scripts that get installed.
rm -f activate-gcc.sh activate-g++.sh activate-gfortran.sh \
      deactivate-gfortran.sh

# Check if (de-)activate scripts can be used in non-Bash shells (ignoring the commonly supported "local" keyword.)
errors=$(find . -name "*activate*.sh" -exec shellcheck -e SC3043 -e SC2050 --severity=info --format=gcc {} \;)
echo $errors
if [[ ${errors} != "" ]]; then
  exit 1
fi
