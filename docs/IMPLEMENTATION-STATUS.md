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

## Next

1. Design `packaging/` — the carve boundaries, starting from the artifact's own
   `info/paths.json`.
2. Decide how each output declares its own `__glibc`; the platform-table
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
