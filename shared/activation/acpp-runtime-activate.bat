@echo off
rem etc\conda\activate.d\acpp-runtime-activate.bat
rem
rem Backend device-bitcode wiring, run on environment activation. Backends
rem are OPT-IN: this only copies bitcode when the corresponding runtime
rem metapackage (acpp-runtime-cuda / ...) has installed the provider.
rem (Copy, not symlink: symlinks need elevation/dev-mode on Windows.)

rem NB Library\bin, NOT Library\lib: acpp resolves its bitcode dir from
rem get_lib_directory(), which on Windows is the directory containing
rem acpp-common.dll (GetModuleHandleA) -- i.e. Library\bin, since DLLs are
rem RUNTIME artifacts there. Using lib/ makes acpp fall back to the
rem build-time CUDA path baked into the binary, which does not exist at
rem runtime (win gets no binary prefix replacement).
rem CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
if exist "%CONDA_PREFIX%\Library\nvvm\libdevice\libdevice.10.bc" (
  if not exist "%CONDA_PREFIX%\Library\bin\hipSYCL\ext\bitcode\ptx" mkdir "%CONDA_PREFIX%\Library\bin\hipSYCL\ext\bitcode\ptx"
  copy /y "%CONDA_PREFIX%\Library\nvvm\libdevice\libdevice.10.bc" "%CONDA_PREFIX%\Library\bin\hipSYCL\ext\bitcode\ptx\libdevice.10.bc" >nul
)
