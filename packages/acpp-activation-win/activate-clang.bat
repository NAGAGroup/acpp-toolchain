@echo on

set "CC=clang.exe"
set "NM=llvm-nm.exe"
set "LD=lld-link.exe"
set "AR=llvm-ar.exe"
set "RANLIB=llvm-ranlib.exe"

set "CPPFLAGS_USED=-DNDEBUG -D_CRT_SECURE_NO_WARNINGS -nostdlib -fms-runtime-lib=dll -fuse-ld=lld -fno-aligned-allocation"
REM The clang resource directory lives UNDER Library on Windows: conda places a
REM package's unix-style tree at %CONDA_PREFIX%\Library, so the builtins archive
REM is Library/lib/clang/<major>/lib/windows/, not lib/clang/<major>/... . The
REM path is passed to lld-link verbatim, so a wrong one is a link error in
REM someone else's build, not a warning here.
set "LDFLAGS=-nostdlib -Wl,-defaultlib:%CONDA_PREFIX:\=/%/Library/lib/clang/@MAJOR_VER@/lib/windows/clang_rt.builtins-@BUILTINS_ARCH@.lib"
set "CFLAGS=@CFLAGS@ %CPPFLAGS_USED%"
