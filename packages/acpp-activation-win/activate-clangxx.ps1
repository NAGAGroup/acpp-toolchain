$Env:CXX="clang++.exe"
$Env:CXXFLAGS="@CXXFLAGS@ " + $Env:CPPFLAGS_USED

# ---- ACPP DELTA: the SYCL environment ------------------------------------
# Carried on the C++ side only; see the .bat for the reasoning.
if (-not $Env:ACPP_TARGETS) { $Env:ACPP_TARGETS = "generic" }
$Env:ACPP_COMPILER_DIR = "$Env:CONDA_PREFIX\Library"
$Env:ACPP_CLANG = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
$Env:ACPP_CPU_CXX = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
