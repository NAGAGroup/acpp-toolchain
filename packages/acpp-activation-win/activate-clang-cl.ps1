# CC and CXX are clang-cl.exe, matching the .bat. A package whose PowerShell
# activation selected a different driver than its cmd activation would give two
# users of the same prefix two different compilers.
$Env:CC="clang-cl.exe"
$Env:CXX="clang-cl.exe"
$Env:NM="llvm-nm.exe"
$Env:LD="lld-link.exe"
$Env:AR="llvm-ar.exe"
$Env:RANLIB="llvm-ranlib.exe"

$Env:CPPFLAGS_USED="-DNDEBUG -D_CRT_SECURE_NO_WARNINGS -fms-runtime-lib=dll -fuse-ld=lld"

# The clang resource directory lives UNDER Library on Windows; see activate-clang.bat.
$Env:LDFLAGS="/DEFAULTLIB:" + $Env:CONDA_PREFIX.Replace('\', '/') + "/Library/lib/clang/@MAJOR_VER@/lib/windows/clang_rt.builtins-@BUILTINS_ARCH@.lib"
# `-Xlinker` was only exposed in v20. It is needed for compatibility with the `flang` CLI
if (@MAJOR_VER@ -ge 20) {
    $Env:LDFLAGS = "-Xlinker " + $Env:LDFLAGS
}

$Env:CFLAGS="@CFLAGS@ " + $Env:CPPFLAGS_USED
# /std:c++17 stays on the clang-cl driver; see the .bat.
$Env:CXXFLAGS="@CXXFLAGS@ /std:c++17 " + $Env:CPPFLAGS_USED

# ---- ACPP DELTA: the SYCL environment ------------------------------------
# clang-cl is one driver for both languages, so it carries the delta itself.
if (-not $Env:ACPP_TARGETS) { $Env:ACPP_TARGETS = "generic" }
$Env:ACPP_COMPILER_DIR = "$Env:CONDA_PREFIX\Library"
$Env:ACPP_CLANG = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
$Env:ACPP_CPU_CXX = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
