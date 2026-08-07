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

## In progress
- Release-lane LLVM 20.1.8 + acpp v25.10.0 build (local, ~2h)

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
