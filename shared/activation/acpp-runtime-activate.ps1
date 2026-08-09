# etc\conda\activate.d\acpp-runtime-activate.ps1
#
# Backend device-bitcode wiring, run on environment activation. Backends
# are OPT-IN: this only copies bitcode when the corresponding runtime
# metapackage (acpp-runtime-cuda / ...) has installed the provider.
# (Copy, not symlink: symlinks need elevation/dev-mode on Windows.)

# NB Library\bin, NOT Library\lib: acpp resolves its bitcode dir from
# get_lib_directory(), which on Windows is the directory containing
# acpp-common.dll (GetModuleHandleA) -- i.e. Library\bin, since DLLs are
# RUNTIME artifacts there. Using lib/ makes acpp fall back to the
# build-time CUDA path baked into the binary, which does not exist at
# runtime (win gets no binary prefix replacement).
# CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
$libdevice = Join-Path $Env:CONDA_PREFIX "Library\nvvm\libdevice\libdevice.10.bc"
if (Test-Path $libdevice) {
  $ptxDir = Join-Path $Env:CONDA_PREFIX "Library\bin\hipSYCL\ext\bitcode\ptx"
  if (-not (Test-Path $ptxDir)) { New-Item -ItemType Directory -Path $ptxDir | Out-Null }
  Copy-Item -Force $libdevice (Join-Path $ptxDir "libdevice.10.bc")
}
