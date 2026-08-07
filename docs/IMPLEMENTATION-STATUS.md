# Implementation status

Working notes for the E2E productionization pass (2026-08-06/07).
Design: naga-labs/SYCLBUILDKIT-DESIGN.md (ratified). Delete when rollout
completes.

## Done
- Workspace skeleton (single root manifest, package-only members)
- shared/build.nu: pinned-fetch + persistent per-lane cache
  (.build-cache/<lane>/), stable -S/-B incremental cmake, spirv-redirect
  script patch, licenses, triple symlinks
- Release lane: all 9 packages (runtime, acpp, llvm-dev, tools, lldb,
  clang/clangxx activation, cuda/intel metapackages)
- Nightly lane: 7 packages (metapackages are lane-agnostic, live in release/)
- Fixes en route: libxml2-devel (conda-forge header split),
  cuda-nvcc-tools (FindCUDAToolkit anchor), nu regex replacement escaping,
  configure gate on build.ninja

## Release lane: BUILT + SMOKE-TESTED ✓ (2026-08-07)
- All 9 packages built; SYCL hello PASSES on CPU (omp) AND NVIDIA RTX 4090
  (CUDA JIT via packaged opt/llc + driver PTX JIT + libdevice symlink)
- Opt-in verified: bare env has NO cuda; ze/ocl fail soft; +acpp-runtime-cuda
  enables GPU
- Key fixes landed: JIT tools (opt/llc/lld) belong to acpp-runtime;
  stable-symlink indirection for the persistent cache incl. find-result
  stability (CMAKE_PREFIX_PATH via links only) + relocatable prefix baking
  (INSTALL_PREFIX/CUDA paths use real placeholder) + reconfigure-on-prefix-
  change + SPIRV-subbuild refresh; rattler-index needs repodata deleted to
  re-read same-name rebuilt files; pixi package cache must be purged when
  rebuilding same version+build

## In progress / next batch
- python_abi run-export leak: ignore in runtime/acpp/llvm-dev/tools (keep in lldb)
- Activation-path smoke (CXX + CMAKE_ARGS), partition co-install check,
  solver audits, acpp test suite gate
- Nightly lane build (LLVM 21.1.8 + develop) — launch after release iteration settles

## Next
- Carve verification across all 5 toolchain slices (partition = no
  overlap, no strays) → adjust globs
- publish-local + solver audits (same-major cf rejected, different-major
  allowed, lane mixing rejected, metapackage envs solve)
- SYCL hello smoke (generic/omp) via both activation paths
- acpp test suite gate (upstream tests/, generic, CPU)
- Nightly lane build (LLVM 21.1.8 + develop HEAD)
- Publish dry-run → prefix.dev (needs auth on this machine)
- win-64 recipes + CI (CI last per ruling)
- README/docs, channel cleanup (yank naga-*), #1981 draft for Jack

## Notes / decisions made in flight
- Nightly version: date via ACPP_NIGHTLY_DATE env at render
  (0.dev0 placeholder locally)
- Boost drop CONFIRMED (configure passed without it)
- lldb python scripting ON => swig+python build deps

## Follow-up (Jack, 2026-08-07 check-in)
- Refactor external projects to pixi source packages (template external/
  pattern) instead of build.nu-fetched sources: SPIRV translator becomes
  `acpp-llvm-spirv` (built against acpp-llvm-dev; acpp-runtime run-dep;
  removes the ExternalProject patch + last in-build fetch); OpenCL
  headers as env-provided find. Isolated, non-breaking swap post-E2E.
