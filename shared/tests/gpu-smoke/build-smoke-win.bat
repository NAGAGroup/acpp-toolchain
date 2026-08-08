@echo off
rem MSVC env (path via ACPP_SMOKE_VCVARS) + the python-script acpp driver.
rem A .bat sidesteps the deno-task-shell -> cmd quoting stack, which mangles
rem escaped quotes in inline task strings.
call "%ACPP_SMOKE_VCVARS%" || exit /b 1
python "%CONDA_PREFIX%\Library\bin\acpp" -O2 --acpp-targets=generic ..\hello.cpp -o smoke.exe
