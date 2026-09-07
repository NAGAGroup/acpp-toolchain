@echo on
REM install-pkg.bat — render and install the win-64 activation scripts.
REM
REM Only .bat and .ps1 exist here to install. Upstream's .sh family is the
REM cross-from-linux path (it demands CONDA_BUILD_WINSDK and exports
REM CONDA_BUILD_CROSS_COMPILATION=1), installed by its install-pkg.sh alone;
REM this fork builds natively and does not carry those scripts at all.
REM
REM Ordering is engineered through FILENAMES, because conda sources
REM activate.d in sorted order: vs%VSYEAR%_y-* sorts after the vs%VSYEAR%
REM compiler vars, and _z- (clangxx) after _y- (clang) because the C++ script
REM consumes the CPPFLAGS_USED that the C script sets.
md "%PREFIX%\etc\conda\activate.d"

REM MAJOR_VER is the LLVM major of the toolchain being activated, and arrives
REM from the recipe. It is NOT derived from %PKG_VERSION%: this lane's version
REM is a DATE, so parsing it would substitute the year into the clang resource
REM directory path.
if "%MAJOR_VER%" == "" (
    echo ERROR: MAJOR_VER is not set
    exit 1
)
if "%VSYEAR%" == "" (
    echo ERROR: VSYEAR is not set
    exit 1
)

REM Only win-64 is built, so the compiler-rt builtins archive has one name.
set "BUILTINS_ARCH=x86_64"

pushd "%PREFIX%\etc\conda\activate.d"
if [%PKG_NAME%] == [acpp-clang_%cross_target_platform%] (
    copy "%RECIPE_DIR%\activate-clang.bat" ".\vs%VSYEAR%_y-%PKG_NAME%.bat"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@CFLAGS@/%FINAL_CFLAGS%/g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@MAJOR_VER@/%MAJOR_VER%/g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@BUILTINS_ARCH@/%BUILTINS_ARCH%/g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1

    copy "%RECIPE_DIR%\activate-clang.ps1" ".\vs%VSYEAR%_y-%PKG_NAME%.ps1"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@CFLAGS@/%FINAL_CFLAGS%/g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@MAJOR_VER@/%MAJOR_VER%/g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@BUILTINS_ARCH@/%BUILTINS_ARCH%/g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
) else if [%PKG_NAME%] == [acpp-clangxx_%cross_target_platform%] (
    copy "%RECIPE_DIR%\activate-clangxx.bat" ".\vs%VSYEAR%_z-%PKG_NAME%.bat"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@CXXFLAGS@/%FINAL_CXXFLAGS%/g' vs%VSYEAR%_z-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1

    copy "%RECIPE_DIR%\activate-clangxx.ps1" ".\vs%VSYEAR%_z-%PKG_NAME%.ps1"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's/@CXXFLAGS@/%FINAL_CXXFLAGS%/g' vs%VSYEAR%_z-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
) else if [%PKG_NAME%] == [acpp-clang-cl_%cross_target_platform%] (
    REM This package conflicts with the clang/clangxx pair by run_constraint, so
    REM its script never has to sort against theirs and takes _y- as well.
    copy "%RECIPE_DIR%\activate-clang-cl.bat" ".\vs%VSYEAR%_y-%PKG_NAME%.bat"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@CFLAGS@;%FINAL_CL_FLAGS%;g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@CXXFLAGS@;%FINAL_CL_FLAGS%;g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@MAJOR_VER@;%MAJOR_VER%;g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@BUILTINS_ARCH@;%BUILTINS_ARCH%;g' vs%VSYEAR%_y-%PKG_NAME%.bat
    if %ERRORLEVEL% neq 0 exit 1

    copy "%RECIPE_DIR%\activate-clang-cl.ps1" ".\vs%VSYEAR%_y-%PKG_NAME%.ps1"
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@CFLAGS@;%FINAL_CL_FLAGS%;g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@CXXFLAGS@;%FINAL_CL_FLAGS%;g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@MAJOR_VER@;%MAJOR_VER%;g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
    sed -i 's;@BUILTINS_ARCH@;%BUILTINS_ARCH%;g' vs%VSYEAR%_y-%PKG_NAME%.ps1
    if %ERRORLEVEL% neq 0 exit 1
) else (
    echo ERROR: unhandled PKG_NAME %PKG_NAME%
    exit 1
)

REM Nothing may survive unrendered: an unsubstituted token in a shipped script
REM is a broken flag in a consumer's build, and it looks fine in the artifact.
REM The pattern is @TOKEN@, not a bare @, so that `@echo on` does not match.
REM
REM ONE GUARD, TWO EXIT CODES, AND THE PASS PATH IS THE AWKWARD ONE.
REM `findstr` returns 0 when it MATCHES and 1 when it does not — so the healthy
REM outcome, no token surviving, leaves ERRORLEVEL 1 behind. Nothing reset it,
REM and rattler-build's wrapper ends every script with an ERRORLEVEL check, so a
REM PASSING guard failed the package: win run 34147813700, with both activation
REM scripts installed correctly and every substitution done.
REM
REM `(call )` is the cmd idiom for "set ERRORLEVEL to 0" — a call to nothing,
REM which succeeds. It runs only on the pass path, after the failure branch has
REM already exited, so the two outcomes stay distinct:
REM   * a token IS found  -> findstr 0 -> the block echoes and `exit 1`;
REM   * no token is found -> findstr 1 -> the block is skipped, `(call )` resets
REM     ERRORLEVEL to 0, and the script ends clean.
findstr /R /C:"@[A-Z_][A-Z_]*@" vs%VSYEAR%_*-%PKG_NAME%.bat vs%VSYEAR%_*-%PKG_NAME%.ps1
if %ERRORLEVEL% equ 0 (
    echo ERROR: unsubstituted @TOKEN@ left in an installed activation script
    exit 1
)
(call )
popd
