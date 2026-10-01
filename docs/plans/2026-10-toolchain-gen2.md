# Proposed plan: toolchain generation 2 (LLVM 23, full toolchain everywhere, Windows libLLVM DLL, HIP)

**Status: PROPOSED — not finalized.** Drafted 2026-10-01 for review with Jack. Every item marked *(decide)* is open. Nothing here has been started.

## Goals (Jack, 2026-10-01)

1. **Full toolchain on every platform.** linux-64, linux-aarch64, osx-arm64, win-64 and win-arm64 all ship every LLVM/Clang tool for our LLVM version: clang-tools-extra (clangd, clang-format, clang-tidy, ...), lldb, llvm-cov/llvm-profdata, and so on. These go in optional, non-required packages. Mixing conda-forge's builds of these tools with our packages is brittle, so we provide the whole set ourselves.
2. **libLLVM as a DLL on Windows** (win-64 and win-arm64).
3. **Bump LLVM 21.1.8 → 23.1.x.**
4. **Make HIP/ROCm work.** It is parked today (`HIP-PARKED (build 2)`).

Standing rules that apply throughout:
- All five platforms must **build and publish**, with identical build numbers.
- Test failures are tolerated and recorded.
- Dispatches always use the full 40-character fork SHA.

## What is true today (verified 2026-10-01, main 8a7a9f5)

**Projects built per platform** (`shared/build-stage.nu`)

| Platform | LLVM_ENABLE_PROJECTS | libLLVM |
|---|---|---|
| linux-64, linux-aarch64 | clang, lld, lldb, clang-tools-extra, bolt, polly, openmp (+ runtime compiler-rt) | dylib, symbol versioning |
| win-64 | clang, lld, clang-tools-extra, openmp, compiler-rt | static (comment: "Windows has no libLLVM dylib", which is stale) |
| win-arm64 | clang, lld, openmp, compiler-rt (builtins only), AArch64 target only | static |
| osx-arm64 | clang, lld, clang-tools-extra, openmp | dylib |

**Package skips** (`recipe.yaml`)

| Package | Skipped on |
|---|---|
| naga-acpp-tools | osx, win-arm64 |
| naga-acpp-llvm-dev | osx, win-arm64 |
| naga-acpp-lldb | win, osx |
| naga-acpp-compiler-rt | osx |

**Where tools land today**
- `llvm-cov`, `llvm-profdata`, `llvm-symbolizer` and the other binutils-style tools already ship in `naga-acpp` on every platform.
- `naga-acpp-tools` uses an **explicit per-file list** (clang-tools-extra, scan-build, bolt, ...). A new tool that matches no output's list is silently dropped.

**Windows DLL**
- Upstream supports it. At `llvmorg-21.1.8`, `llvm/tools/llvm-shlib/CMakeLists.txt` only FATAL_ERRORs on MSVC when `LLVM_BUILD_LLVM_DYLIB_VIS` is OFF.
- The upstream recipe (LLVM Discourse, "LLVM is buildable as a Windows DLL", Aug 2025) is `LLVM_BUILD_LLVM_DYLIB=ON`, `LLVM_BUILD_LLVM_DYLIB_VIS=ON`, `LLVM_LINK_LLVM_DYLIB=ON` and `CLANG_LINK_CLANG_DYLIB=OFF`. Clang stays static on Windows: there is no clang-cpp DLL.
- Known caveats: `LLVM_ABI` annotations are missing on newer code, and polly's `getPollyPluginInfo` fails against the DLL. Polly isn't built on Windows today.

**LLVM 23**
- 23.1.0 was released 2026-08-26, and 23.1.1 on 2026-09-08. Take the latest 23.1.x at execution time.
- 23.1 also brings the new AMD HIP offload driver.

**The fork can't build against 23 yet** (`acpp-fork` `naga/develop` a0972d64)
- `CMakeLists.txt:482` errors for LLVM > 21 unless `ACPP_EXPERIMENTAL_LLVM` is set.
- Port items, all known from upstream:
  - The `PassPlugin.h` header moved to `llvm/Plugins/PassPlugin.h` in 22+.
  - `--enable-unsafe-fp-math` was removed in 22. It is still pushed at `LLVMToHost.cpp:342` and `LLVMToPtx.cpp:239`.
  - The LifetimeIntrinsic argument-count change (llvm `c23b4fbd`) segfaults SSCP SPIR-V and AMDGCN (HeCBench fft).
  - `__amdgcn_get_dynamicgroupbaseptr` was removed. Upstream PR #2039 (merged) replaces it with `extern __shared__`.
  - The SPIRV-LLVM-Translator ExternalProject wants branch `llvm_release_230` in `AdaptiveCpp/SPIRV-LLVM-Translator`.
- References:
  - Upstream PR #1986 "Support LLVM 22" was still a draft as of June 2026.
  - Issue #2041 covers the LLVM 23 build failures.
  - `al42and/SPIRV-LLVM-Translator-ACpp` is an auto-updated translator mirror.

**HIP blocker**
- TheRock 10.0.0's Linux `libamd_comgr.so.3` dynamically links `libLLVM.so.23.0git` and `libclang-cpp.so.23.0git` (symbol version `LLVM_23.0`).
- Our `libLLVM.so.21` is in the same process (llvm-to-backend/JIT), and the process aborts with "CommandLine Error: Option ... registered more than once".
- Symbol versioning did not prevent it.
- The same class of failure is reported in ROCm/ROCm #6511 (open, ROCm 7.14, interposition between ROCm's libLLVM and another LLVM) and AdaptiveCpp #1403.
- On Windows, TheRock builds amd-llvm **statically** (`LLVM_BUILD_LLVM_DYLIB OFF` on WIN32 in `compiler/pre_hook_amd-llvm.cmake`), and DLLs have separate symbol namespaces. So the Linux blocker should not apply there.

**AdaptiveCpp's SSCP/ROCm rule:** AdaptiveCpp's LLVM must be **≤ ROCm's LLVM**. When the versions are equal, real IR-attribute breakage has been seen: ROCm 7.2's LLVM 22.0git couldn't read attributes from 22.1. TheRock 10.0.0 is 23.0git, and 23.1.x is newer.

## Plan

There are four phases. A and B ship together. C is gated and must not hold up A or B. D is the release.

### Phase A — LLVM 23 bump (branch `gen2` in both repos; local channel only)

**A1. Port the fork** on a branch off `naga/develop`.
- Bump the version cap to 23. Don't rely on `ACPP_EXPERIMENTAL_LLVM` in the shipped build.
- Version-guard the PassPlugin include.
- Drop `--enable-unsafe-fp-math` for LLVM ≥ 22. Keep the other fast-math flags.
- Fix the LifetimeIntrinsic call sites.
- Apply #2039.
- First check whether #1986 has merged upstream; if so, cherry-pick it instead of reimplementing.

**A2. Translator source.**
- Check for `llvm_release_230` in `AdaptiveCpp/SPIRV-LLVM-Translator`.
- If it isn't there, pin `LLVMSPIRV_COMMIT` to a fixed SHA from a translator fork (our own mirror is preferred over al42and's). This is already supported by `src/compiler/llvm-to-backend/CMakeLists.txt`.
- *(decide)* Which source we use.

**A3. Toolchain recipe.**
- Update `llvm_version`, `llvm_major` (23), `llvm_major_next` (24), `llvm_maj_min` and the src sha256.
- Re-check patches 0009 (crashrecovery `<sys/resource.h>` on Apple) and 0011 (ProgramStack `<cstdlib>`), and drop each one if upstream has fixed it.
- Run `gen-staging-hash`.
- The mutex follows `llvm_major` automatically. Re-check the same-major `run_constraints` windows and `check-no-collision` against conda-forge's LLVM 23 package names.
- Update the clang build dependency pin (`clang ==${{ llvm_version }}`). This requires conda-forge to have clang 23.1.x for every platform, including win-arm64, so check that first.

**A4. Build order.**
- Linux first, with fast iteration (~10–15 min fresh), then osx, then Windows (~30 min).
- Use non-publishing dispatches until all five are green.

### Phase B — Windows DLL and the full tool set (same branch)

**B1. Windows libLLVM DLL**
- **win-64 first.**
  - Set the four upstream flags in `windows-args`, and replace the stale comment.
  - Extend the "build the `LLVM` target first" step (Linux-only today, it prevents the SPIRV-translator ExternalProject race) to Windows, because the translator will now link the import library.
- **Recipe:**
  - `Library/bin/LLVM-23.dll` goes in the same output as `libLLVM.so` on Linux (`naga-acpp-runtime`).
  - The import library `Library/lib/LLVM-23.lib` goes in `naga-acpp-llvm-dev`.
  - Static component libs stay in llvm-dev.
- **Check:** the exported-symbol count is under the PE limit of 65,535.
- **If annotation gaps break the link:** carry minimal `LLVM_ABI` patches in `shared/patches/`. If that balloons, *(decide)* whether to ship win-64 static for this generation.
- **Then win-arm64.**

**B2. Every tool, every platform**
- **Projects:**
  - Add `clang-tools-extra` and `lldb` to win-arm64.
  - Add `lldb` to win-64 and osx.
  - Add `compiler-rt` to osx. Note that the osx sanitizer story was deferred as "its own pass".
- **Exceptions:**
  - BOLT stays Linux-only because it is ELF-only upstream.
  - Polly stays Linux-only unless it builds cleanly against the Windows DLL. *(decide)*
- **Recipe:** remove the osx and win-arm64 skips on `naga-acpp-tools` and `naga-acpp-llvm-dev`, the win and osx skips on `naga-acpp-lldb`, and the osx skip on `naga-acpp-compiler-rt`. Add per-platform `files` globs.
- **New gate, "every staged file is claimed".** For each platform, list the staged prefix and fail if any file under `bin/`, `lib/` or `share/` (`Library/...` on Windows) belongs to **no** output or to **more than one**. This turns "a tool silently didn't ship" into a CI failure, which is the property Jack is asking for. Implement it as a `check-partition` task alongside `check-closure`.
- **lldb on macOS:** use `LLDB_USE_SYSTEM_DEBUGSERVER=ON` so lldb uses Xcode's signed debugserver, and document this in the README. Building and codesigning our own debugserver needs entitlements and is out of scope.
- **lldb on Windows:**
  - Python and swig are `if: linux` in the recipe host today.
  - First cut is `LLDB_ENABLE_PYTHON=OFF` on Windows. Python scripting is a follow-up. *(decide)*
- **Package shape:**
  - Tools stay optional; nothing in `naga-acpp` depends on them.
  - *(decide)* Keep `naga-acpp-tools` as one package or split it (for example clang-tools, lldb, bolt).
  - *(decide)* Whether a `naga-acpp-full` metapackage pulls in everything.
- **Smoke tests:** every tool gets at least `--version`. clang-format and clang-tidy run on a small file. lldb runs `lldb --batch -o 'version'`. These run in the test stage, so failures are recorded and don't block publishing.

### Phase C — HIP (gated; Linux and Windows handled separately)

The blocker is **two LLVMs in one process**. Moving to 23 alone does not fix it, because TheRock's comgr links `libLLVM.so.23.0git` and ours would be `libLLVM.so.23.1`.

**C0. Reproduce and characterize** on the published LLVM 21 packages, before Phase A finishes.
- Use a minimal program that loads our llvm-to-backend (libLLVM) and TheRock's `libamd_comgr.so.3`.
- Record:
  - `readelf -Ws --wide libLLVM.so | grep -c UNIQUE`, for ours and for TheRock's
  - `LD_DEBUG=bindings`: which `cl::` / `GlobalParser` symbols bind across the two libraries
- **Working hypothesis:** our libLLVM is built by GCC (conda toolchain), which emits `STB_GNU_UNIQUE` for inline and template statics. glibc binds those process-wide by name, regardless of symbol version, so both LLVMs share one option registry. TheRock builds with clang, which does not emit them.

**C1. Candidate fixes**, cheapest first. Each is judged by the C0 harness on a real comgr load, not by a symbol dump.
- **(a) No GNU unique objects.** Build our LLVM with `-fno-gnu-unique`, or with clang, keeping symbol versioning. This is the cheapest option and touches only build flags.
- **(b) Minimal exports on Linux.** Set `LLVM_BUILD_LLVM_DYLIB_VIS=ON` on Linux too, so only `LLVM_ABI`-annotated symbols are exported. This shares the annotation work with B1. The risk is that AdaptiveCpp's llvm-to-backend and the clang integration use unannotated internals.
- **(c) Out of process.** Run AMDGPU code generation out of process, so our LLVM and comgr never share an address space. This is the most robust option, but it is a fork design change.
- **(d) Build comgr against our LLVM.** Build comgr from ROCm/llvm-project against our LLVM. This is a last resort, because comgr tracks amd-llvm-specific APIs.

**C2. Version ordering.**
- With 23.1.x against TheRock 10.0.0 (23.0git), run SSCP→AMDGCN end to end.
- If IR-attribute or reader errors appear, *(decide)* between:
  - waiting for a TheRock built on ≥ 23.1
  - a TheRock-matched device-libs build
  - accepting SMCP-only HIP for now
- The device-libs workaround is already proven: we built ROCm device-libs (rocm-7.1.1 tag) with our own clang so the bitcode matches our LLVM. Redo it at the matching tag for 23.

**C3. Unpark.** Only after C1 and C2 pass on linux-64:
- Revert every `HIP-PARKED (build 2)` site:
  - `build-stage.nu` (5 sites, including `-DACPP_HIP_ROOT=.` and `-DWITH_ROCM_BACKEND=OFF`)
  - `recipe.yaml` (the TheRock source block, the runtime-rocm output, and the HIP excludes in runtime and naga-acpp)
  - `shared/tests/suite/pixi.toml`
  - the README
- Re-pin the TheRock tarballs by sha256.
- Run a `readelf` NEEDED/RUNPATH audit on every vendored ROCm binary.
- linux-aarch64: *(decide)* whether TheRock ships aarch64. If not, HIP stays x86-64 only.

**C4. Windows HIP** (win-64 only; no ROCm on win-arm64).
- The process-collision blocker should not apply, because TheRock's Windows comgr links LLVM statically.
- Still pending from before: verifying the Windows ROCm tarball layout.
- Validate that `rt-backend-hip.dll` and `llvm-to-amdgpu-tool.exe` load next to our `LLVM-23.dll`.
- This can unpark independently of Linux. *(decide)*

**If Phase C isn't ready, A and B ship with HIP still parked.**

### Phase D — Release

1. Dispatch all five platforms with publish on, identical build numbers and the full fork SHA.
2. Gates: `check-staging-hash`, `check-pins`, `check-no-collision`, `check-closure`, and the new `check-partition`.
3. The test stage runs the suite plus the per-tool smoke tests. Failures are recorded and don't block.
4. Merge the `gen2` branches in the fork and the toolchain. Update the recipe default `acpp_commit`.
5. Downstream (cospan, slabkit) repin to the new set. That is a separate step.

## Risks

| Risk | Mitigation |
|---|---|
| The fork's LLVM 23 port is bigger than the known items | Start with A1 on day one. Track upstream #1986 and #2041. |
| conda-forge lacks clang 23.1.x on some platform (win-arm64 especially) for the build dependency | Check before A3. Fall back to a stage-1 bootstrap for that platform. |
| Windows DLL annotation gaps | Local patches. *(decide)* fallback to static for one generation. |
| More projects means longer builds (lldb and clang-tools-extra on win-arm64) | Large runners, staging-cache diet, Dev Drive on win-64. Measure on the first build. |
| HIP fixes don't hold in a real process (ROCm #6511 shows interposition in the wild) | C is gated. Test with real comgr loads, not symbol dumps. |
| The partition gate finds existing unclaimed files | Expected. Fix them as part of B2. |

## Open decisions (for the review)

1. The translator source for LLVM 23 (A2).
2. The Windows DLL fallback if annotations break (B1).
3. Polly on Windows and osx (B2).
4. lldb Python on Windows: now or later (B2).
5. Package shape: one `naga-acpp-tools` or a split, and whether there's a `-full` metapackage (B2).
6. The HIP isolation approach: chosen by C0/C1 results.
7. HIP version ordering: what to do if 23.1 versus 23.0git breaks SSCP (C2).
8. HIP on linux-aarch64 and on win-64: whether each unparks independently (C3, C4).

## Sources

- LLVM 23.1.0 release announcement: https://discourse.llvm.org/t/llvm-23-1-0-released/91654
- LLVM as a Windows DLL: https://discourse.llvm.org/t/llvm-is-buildable-as-a-windows-dll/87748
- llvm-shlib at 21.1.8: https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/llvm/tools/llvm-shlib/CMakeLists.txt
- AdaptiveCpp LLVM 22 support (draft): https://github.com/AdaptiveCpp/AdaptiveCpp/pull/1986
- AdaptiveCpp LLVM 23 build failures: https://github.com/AdaptiveCpp/AdaptiveCpp/issues/2041
- AdaptiveCpp dynamic LDS fix: https://github.com/AdaptiveCpp/AdaptiveCpp/pull/2039
- AdaptiveCpp duplicate cl::opt abort: https://github.com/AdaptiveCpp/AdaptiveCpp/issues/1403
- ROCm libLLVM interposition: https://github.com/ROCm/ROCm/issues/6511
- TheRock amd-llvm build config: https://github.com/ROCm/TheRock/blob/main/compiler/pre_hook_amd-llvm.cmake
- LLDB debugserver signing options: llvm-project `lldb/tools/debugserver/source/CMakeLists.txt` (`LLDB_USE_SYSTEM_DEBUGSERVER`)
