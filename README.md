# acpp-toolchain

Conda packages for [AdaptiveCpp](https://github.com/AdaptiveCpp/AdaptiveCpp) — the independent, community-driven SYCL implementation for CPUs and GPUs from every vendor — built as a **complete, standalone LLVM toolchain**: compiler, linker, debugger, and the full clang tool suite from a single conda channel, maintained from the HPC/SYCL space.

AdaptiveCpp is compiled **linked into LLVM** (the upstream-recommended flow) with the **generic single-pass (SSCP) compiler** as the only compilation mode: kernels compile once to portable IR and JIT to whatever hardware is present at runtime — NVIDIA GPUs, Intel GPUs, CPUs — no recompilation, no per-vendor binaries.

Packages live on the [`jackm97/naga-labs`](https://prefix.dev/jackm97/naga-labs) channel.

## The suites

| | Release | Nightly |
|---|---|---|
| Tracks | AdaptiveCpp release tags | head of AdaptiveCpp `develop`, daily |
| LLVM | newest the release supports (currently **20.1.8**) | newest `develop` supports (currently **21.1.8**) |
| Version | `25.10.0_llvm20.1.8` | `2026.08.06_llvm21.1.8` |
| Packages | `acpp`, `acpp-runtime`, … | `acpp-nightly`, `acpp-runtime-nightly`, … |

The two suites ship the same file paths and are **mutually exclusive** in one environment (enforced via `run_constraints`) — pick a lane per environment.

## Packages

| Package | What | Install into |
|---|---|---|
| `acpp-runtime` | runtime shared libs, JIT backend plugins + bitcode | consumer envs (arrives automatically via run-exports) |
| `acpp` | the SYCL compiler: `acpp`, clang, lld, llvm binutils, SYCL headers, CMake config | build envs |
| `acpp-clang_linux-64` / `acpp-clangxx_linux-64` | compiler **activation** (CC-side / CXX-side): sysroot wiring for redistributable, glibc≥2.28 builds; strong run-exports | build envs — or via `cxx_compiler = ["acpp-clangxx"]` build-variants |
| `acpp-tools` | clang-format / clang-tidy / clangd / clang-tools-extra / BOLT, same LLVM as the compiler | dev envs |
| `acpp-lldb` | LLDB (python scripting enabled), same LLVM | dev envs |
| `acpp-llvm-dev` | LLVM/Clang C++ API headers, static libs, `LLVMConfig.cmake` | building against the LLVM API |
| `acpp-compiler-rt` | compiler-rt sanitizer/profile runtimes — ASan, TSan, UBSan, profile, libFuzzer (plus XRay/MemProf/ORC on linux) | envs that build with `-fsanitize=…` or coverage |
| `acpp-llvm` | the **lane mutex**: bare-major versions (`20`, `21`) naming which LLVM the toolchain was linked against | pulled automatically; pin it only to force a lane |
| `acpp-runtime-cuda` | opt-in CUDA runtime pieces (cudart + libdevice — precisely those, nothing more) | consumer envs |
| `acpp-runtime-intel` | opt-in Intel GPU pieces (Level Zero loader + OpenCL ICD loader) | consumer envs |

## Install

```toml
# pixi.toml
[workspace]
channels = ["https://prefix.dev/jackm97/naga-labs"]
platforms = ["linux-64"]
channel-priority = "strict"
```

**One channel, deliberately.** `naga-labs` layers conda-forge server-side — its
repodata declares conda-forge as its base — so everything conda-forge provides
resolves through it. Listing `conda-forge` separately is unnecessary and works
against the layering. `channel-priority` is stated explicitly rather than left
to the default because this channel is overlay-first, and a setting that
important should be visible in your manifest rather than inherited.

```sh
pixi add acpp            # the compiler (runtime arrives via run-exports)
pixi add acpp-tools      # formatter/LSP/tidy matching your compiler
```

## Backends

CPU (OpenMP) works out of the box. GPU backends are **opt-in** — add the runtime metapackage; the JIT discovers what's present at runtime:

```sh
pixi add acpp-runtime-cuda    # NVIDIA: needs a CUDA 12 driver on the host
pixi add acpp-runtime-intel   # Intel GPUs: needs Intel compute drivers on the host
```

Check what the runtime sees with `acpp-info`.

### AMD / ROCm status — honest version

Currently **not shipped**. The generic JIT requires acpp's LLVM ≤ ROCm's LLVM
(the JIT hands LLVM bitcode to ROCm's compiler), and conda-forge's HIP runtime
is still ROCm 6.3 (LLVM 18) — there is no installable configuration in which
AMD dispatch works with this toolchain's LLVM. The moment conda-forge lands
`hip-runtime-amd >= 7.2` (built on LLVM 22), the ROCm backend and an
`acpp-runtime-rocm` metapackage ship in a rebuild. Track:
[conda-forge ROCm migration](https://github.com/conda-forge/rocm-device-libs-feedstock).

## Compiling

```sh
acpp -O2 -o prog prog.cpp        # direct
```

```cmake
find_package(AdaptiveCpp REQUIRED)
add_executable(prog prog.cpp)
add_sycl_to_target(TARGET prog)
```

For **redistributable** builds (conda packages, glibc-2.28 floor), install the
activation pair — it sets `CC`/`CXX`, sysroot, hardened flags, and stamps
correct runtime dependencies onto whatever you build:

```sh
pixi add acpp-clang_linux-64 acpp-clangxx_linux-64
```

Or select it as a compiler in pixi build-variants: `cxx_compiler = ["acpp-clangxx"]`.
A CMake toolchain file ships at `$CONDA_PREFIX/share/acpp/toolchain/acpp-toolchain.cmake` for IDE/direct-cmake use.

## Choosing an LLVM lane

The toolchain version is the **AdaptiveCpp** version and nothing else, so an
ordinary range works:

```toml
acpp = ">=25.10.0,<25.11.0a0"
```

Which LLVM it was linked against is a separate axis, selected through the
`acpp-llvm` mutex — the same shape the ecosystem uses for `python_abi` and
`cuda-version`:

```toml
acpp-llvm = "==20"      # pin the lane explicitly; optional
```

Versions of `acpp-llvm` are **bare majors** — `20`, `21`. There is no
`acpp-llvm 20.1.8`: a release lane tracks one stable LLVM major at whatever its
latest patch happens to be, so there is nothing for a third segment to say.

You rarely need to write this. Anything compiled with the toolchain receives
both the runtime range and its lane automatically through run-exports, which is
what stops a binary built against the llvm20 toolchain from being installed
next to an llvm21 runtime.

> `acpp-llvm` is **not** `acpp-llvm-dev`. The latter ships the LLVM/Clang
> development files and is never the pinning handle.

## Coexistence with conda-forge clang/llvm

Deliberate and precise: the suite forbids conda-forge's LLVM family **only at
the major we ship**. That covers the ABI packages (`libllvm20`,
`libclang-cpp20.1`), which are major-scoped by name, and — as of the phase-3
redesign — the unversioned bin-name owners (`clang`, `llvm-tools`, `lld`,
`clang-format`, `lldb`, …), which are now constrained to a same-major *window*
rather than forbidden outright.

The practical difference: a **different-major** conda-forge `clang-format`,
`clangd` or `lldb` co-installs cleanly, so a project can keep its own pinned
dev tooling alongside this toolchain. Only a same-major one is refused, and
there it is a genuine file collision rather than a matter of taste.

Same-major conda-forge dev tools can't coexist by construction (they link
`libclang-cpp`) — that's what `acpp-tools`/`acpp-lldb` are for.

## Consuming from source (pixi)

Every package here is a pixi source package; external projects can build the
toolchain from source instead of the channel:

```toml
[package.build-dependencies]
acpp = { git = "https://github.com/NAGAGroup/acpp-toolchain", subdirectory = "release/acpp" }
```

Fair warning: the first resolve compiles LLVM on your machine (hours). The
channel binaries are the happy path; source consumption exists for pinning
purists and CI reproducibility.

## Windows

In progress (phase 2): the linked-into-LLVM flow is exactly what enables
Windows; upstream CI already proves it. Follow the issues.

## Building this repo

```sh
pixi run build-release     # populates .build-cache/<lane>/ (LLVM: hours, once)
pixi run publish-local     # all packages → ./local-channel
```

`shared/build.nu` (nushell, cross-platform) owns pinned source acquisition and
the persistent per-lane CMake build cache; recipes are thin per-package carves.

## License

Toolchain packages: Apache-2.0 WITH LLVM-exception (LLVM, AdaptiveCpp).
Packaging: BSD-3-Clause.
