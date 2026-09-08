# Implementation status

Working notes — volatile by design. Delete when the rollout completes. The
durable architecture is in `DESIGN.md`; external source material is in
`knowledge-base/`.

Last updated 2026-09-08.

## Where things stand

**`staging/` is green on linux-64.** Run 34206367852 built the whole toolchain
with zero failed targets and published the asset. Twelve runs to get there; the
fixes are listed under "decisions in flight" below.

**`packaging/` does not exist yet.** The branch has `staging/`, `docs/` and the
workflow, nothing else.

### The artifact

```
tag     staging-linux-64          (prerelease)
file    acpp-stage-1.0-<hash>.tar.bz2
size    ~323 MB
url     https://github.com/NAGAGroup/acpp-toolchain/releases/download/staging-linux-64/<file>
```

sha256 is readable from the releases API as `assets[].digest`.

**The tag is still moving.** A re-publish is in flight to correct the declared
`__glibc` floor from pixi's default 2.28 to our stated 2.34. Once
`packaging/` pins a sha256, the tag freezes.

### Shape of the tree, for carve design

```
lib        843 files   1131.3 MiB    1048.7 MiB of it loose in lib/
bin        145 files    172.0 MiB
targets   4901 files    127.5 MiB    all of it targets/x86_64-linux
include   5008 files     71.3 MiB
share       65 files      0.6 MiB
libexec      6 files      0.0 MiB
etc          7 files      0.0 MiB
```

`targets/x86_64-linux` is already exactly the ROCm and CUDA slice.
`lib/hipSYCL` (105 files, 6.5 MiB) is acpp's own runtime tree. The difficulty
is `lib/` itself: 1.05 GB across 229 loose files, where every LLVM, clang and
tooling boundary lives, separable only by filename.

## The package split — PROPOSED, not ratified

Approved 2026-09-08, with one pass still owed against the next tarball (the
newly-installed LLVM utils). Activation packages are NOT designed here.
Order of work was slices, then dependency specs, then activation.

Deliberately NOT conda-forge's 40-plus package split: that is an unbearable
maintenance burden for a one-person team, on a toolchain that may never see
wide use. The point is splitting, not trimming — a large HPC toolchain is
normal, and installing more beats missing a shared library at runtime.

### The two use cases the split serves

- **Base packages** are the "I do not care about sysroots or packaging" case:
  `pixi global install acpp` gives a working SYCL compiler that builds against
  whatever system it is on. No cfg files, no triplet, no sysroot pinning, zero
  isolation. Prefix libraries take priority and the system is a real fallback.
- **The activation package** is the "I care about sysroots and packaging" case
  and is where the cfg files live. Generated from upstream's activation
  feedstocks repointed at our packages. Not designed yet.

### Contents

| package | holds |
|---|---|
| `acpp-compiler-rt` | THE runtime, and the base of the graph: `libacpp-rt`, `libacpp-common`, `rt-backend-omp`, `llvm-to-host`, `llvm-to-backend`, host bitcode, `libLLVM`, sanitizer `.so`, our own OpenMP runtimes, and `llc`/`opt`/`ld.lld`. |
| `acpp-dev` | static archives, all headers, all cmake config. ~900 MiB, intended. |
| `acpp` | the 17 executables and `etc/AdaptiveCpp/*.json`. **No cfg files.** |
| `acpp-clang-tools` | clangd, tidy, format, the scan-build family, `libclang`, `libclang-cpp`, and their supporting files. |
| `acpp-llvm-tools` | the `llvm-*` family, bugpoint, and lldb with `liblldb.so` and its Python bindings. |
| `acpp-runtime-rocm` | `rt-backend-hip`, `llvm-to-amdgpu`, amdgpu bitcode, and `targets/x86_64-linux`. The only runtime that repackages files. |
| `acpp-runtime-cuda` · `-level-zero` · `-ocl` | that backend's `rt-backend-*`, `llvm-to-*` and bitcode; otherwise metapackages over conda-forge. |
| `acpp-runtime-ocl-system` | metapackage adding `ocl-icd-system`. |
| `acpp-toolkit` | root meta package. |

**OpenMP is baked into `acpp-compiler-rt` unconditionally** so that every
install has one working backend regardless of hardware. The other backends are
sliced out so their conda dependencies are not forced on everyone; acpp loads
backends fail-soft, and this also removes the "backend not found" warning at
the default debug level.

**The runtime needs three EXECUTABLES** — `llc`, `opt`, `ld.lld` — because acpp
JITs at run time and shells out to them. They live in `acpp-compiler-rt`. That
is a design philosophy question, not a rule: "`acpp` holds the executables"
describes what `acpp` contains, not a prohibition elsewhere.

### Dependencies — stated once, at the package that owns them

`acpp-compiler-rt` is the base, so what it pulls reaches everything through it.

| package | conda-forge | ours |
|---|---|---|
| `acpp-compiler-rt` | `libgcc >=14`, `libstdcxx >=14`, `libzlib`, `zstd`, `libxml2`, `libxml2-16`, `ncurses`, `libedit`, `libnuma` | — |
| `acpp-dev` | `libstdcxx-devel_linux-64`, `libgcc-devel_linux-64` | `acpp-compiler-rt ==${version}` |
| `acpp` | `python` | `acpp-dev ==${version}` |
| `acpp-clang-tools` | `python` | `acpp-compiler-rt ==${version}` |
| `acpp-llvm-tools` | `python`, `python_abi` | `acpp-compiler-rt ==${version}` |
| `acpp-runtime-cuda` | `cuda-version >=12.9,<13`, `cuda-cudart` | `acpp-compiler-rt ==${version}` |
| `acpp-runtime-level-zero` | `level-zero >=1.29.0,<2.0a0` | `acpp-compiler-rt ==${version}` |
| `acpp-runtime-ocl` | `ocl-icd >=2.3.4,<3.0a0` | `acpp-compiler-rt ==${version}` |
| `acpp-runtime-ocl-system` | `ocl-icd-system` | `acpp-runtime-ocl ==${version}` |
| `acpp-runtime-rocm` | — | `acpp-compiler-rt ==${version}` |

Two the artifact's metadata cannot show, because rattler only sees ELF linkage:
`python` on `acpp` (`bin/acpp` is a Python script) and the two `*-devel_linux-64`
packages on `acpp-dev` (our headers include libstdc++'s, our archives were
compiled against them, and `libstdcxx-devel_linux-64` has no dependencies of its
own so it does not pull `libgcc-devel`).

No `sysroot_linux-64`, `binutils` or `libgcc-devel` on `acpp` — those belong to
the activation package, because the base is the no-isolation case. No
`llvm-openmp`: we build and ship our own.

### Exports

A package's **strong** exports fire when it is in a consumer's BUILD
environment, landing in that consumer's host and run. Its **weak** exports fire
when it is in HOST, landing in run. Exports do not chain — upstream states this
twice in `ctng-compiler-activation`: *"this should be a transitive dependency,
but conda-build doesn't support those"*.

- `acpp-compiler-rt` — **weak**, of itself. It is a host dependency in every
  path that reaches it, and weak is what turns "in host" into "in run".
- `acpp-dev` — **weak**, of `acpp-compiler-rt ==${version}`.
- `acpp` — none. The activation package lands in build, so the strong export
  belongs there.

### Constraints

Exact `==${version}` among our own packages; every one is a slice of one build.

Against conda-forge, driven by what actually collides on a filename rather than
by family. Unversioned names collide regardless of major:
`clang`, `clangxx`, `clang-cl`, `clang-tools`, `clang-format`,
`clang-scan-deps`, `llvm-tools`, `lld`, `lldb`, `llvm-spirv`, `compiler-rt`,
`llvm-openmp`. Versioned names collide only at ours: `libllvm21`, `clang-21`,
`libclang21`, `libclang-cpp21.1`, `compiler-rt21`, `clang-format-21`,
`llvmdev`, `clangdev`. Not constrained: `libcxx`, `libcxx-devel` — we build
against libstdc++ on linux and ship no libc++.

**Measured cost of the `libllvm21` constraint, 2026-09-08**: nothing sampled on
the channel depends on it. `qt6-main` uses `libllvm20`, `halide` `libllvm19`,
`mesalib` vendors its own `mesa-llvmpipe`, `numba` reaches LLVM through
`llvmlite` which links it statically, and `pocl` declares none. Six majors are
live (18-23). conda-forge's global pin is `clang_compiler_version: 21`, so the
collision surface is packages being BUILT today, not packages being installed.
Staying at 21 was judged right: anything built against a prior LLVM is still
recent, and LLVM is forward compatible.

### Open

- One pass against the next tarball for the newly-installed LLVM utils.
- The mutex: needed (an acpp version is identical across LLVM variants, which no
  version pin can express), but its name and shape are undecided in this split.
  `acpp-llvm` was `main`'s name and does not carry over automatically.
- `lib/cmake/OpenSYCL/` — upstream's pre-rename compatibility alias. Shipping it
  means a consumer's `find_package(OpenSYCL)` resolves against us.
- `libLTO.so` / `libRemarks.so` — linker-side rather than JIT-side, so `acpp`
  rather than `acpp-compiler-rt`, unconfirmed.

## Next

1. Ratify the split above, then dependency specs, then activation packages.
2. Fix the build-machine leaks in acpp's generated manifests (see below).
3. Decide how each output declares its own `__glibc`; the platform-table
   mechanism is understood for `staging/` but untested for a slicer.

## Open

| item | owner | blocked on |
|---|---|---|
| Re-publish to correct `__glibc` to 2.34, then freeze the tag | — | run in flight |
| `.artifacts/` should be in `.gitignore` before any broad `git add` | Jack | one line, unapproved |
| `libhsakmt` does not exist in this ROCm, so acpp writes `HSAKMT_LIBRARY-NOTFOUND` into its own deploy manifest — a fork fix for `--acpp-deploy` users | — | lands with the runtime package |
| Whether the other `variants.yaml` keys behave as intended; only `c_stdlib_version` was proven not to | — | unblocked |
| win-64 and osx-arm64 | — | linux-64 first, deliberately |

## Decisions made in flight (2026-09-08)

Each of these was a red that had never executed before, diagnosed rather than
guessed. Reasons are recorded at the code sites; `DESIGN.md` carries the ones
that outlive the fix.

- **ROCm selection rewritten** from directory mirroring to destination-driven
  naming, with `cp -P`. 145.8 MB from 8.9 GB, ~90 MB of the saving from not
  triplicating symlinked libraries.
- **`LLVM_HOST_TRIPLE`** set to the conda triple; without it clang's own GCC
  search misses conda's toolchain entirely.
- **Clang config files** written into the build tree, named with the host
  triple so device bitcode compiles do not pick up `-march=nocona`.
- **`-fno-merge-constants` stripped from those config files only.** With it
  present, all 110 compiler-rt feature probes fail — CMake reads clang's
  warning as probe failure — which drops `-nostdinc++` and breaks nsan.
- **`HIP_PLATFORM=amd` stated explicitly.** `hip-config.cmake` otherwise
  executes `hipconfig --platform`, which answers `nvidia` on a CUDA-equipped
  runner and yields HIP targets carrying no library at all.
- **`cmake >=3.28,<4`.** conda-forge pins cmake nowhere globally, so an
  unbounded requirement took 4.4.
- **Virtual packages declared on the platform**, not left to pixi's defaults.

### Fork changes (`NAGAGroup/AdaptiveCpp`, `naga/develop`)

- `ACPP_SPIRV_CMAKE_ARGS` — lets the caller configure the SPIR-V translator
  sub-build, which inherits nothing and otherwise finds a distribution LLVM.
- Threads as a **usage requirement** — `acpp-rt` linked `Threads::Threads`
  PRIVATE while exposing a `std::thread` member in a public header, so no
  backend inherited it. Invisible from glibc 2.34 where `pthread_create` is in
  libc; a link failure below it. `rt-backend-omp` now names Threads itself.

Both are upstreamable and self-contained.
