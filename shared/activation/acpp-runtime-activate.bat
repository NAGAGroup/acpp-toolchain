@echo off
rem etc\conda\activate.d\acpp-runtime-activate.bat
rem
rem Backend device-bitcode wiring, run on environment activation. Backends
rem are OPT-IN: this only copies bitcode when the corresponding runtime
rem metapackage (acpp-runtime-cuda / ...) has installed the provider.
rem (Copy, not symlink: symlinks need elevation/dev-mode on Windows.)

rem CUDA libdevice (from cuda-nvvm via acpp-runtime-cuda)
if exist "%CONDA_PREFIX%\Library\nvvm\libdevice\libdevice.10.bc" (
  if not exist "%CONDA_PREFIX%\Library\lib\hipSYCL\ext\bitcode\ptx" mkdir "%CONDA_PREFIX%\Library\lib\hipSYCL\ext\bitcode\ptx"
  copy /y "%CONDA_PREFIX%\Library\nvvm\libdevice\libdevice.10.bc" "%CONDA_PREFIX%\Library\lib\hipSYCL\ext\bitcode\ptx\libdevice.10.bc" >nul
)
