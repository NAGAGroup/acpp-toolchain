// Sanitizer smoke for acpp-compiler-rt.
//
// The point is NOT to be a clever test. It is to prove that the runtimes we
// now build and ship actually LINK and FIRE through the acpp/clang driver —
// the toolchain claims to be a drop-in replacement for a conda-forge clang,
// and `-fsanitize=address` failing to link is exactly the way that claim
// silently stopped being true before phase 3.
//
// Built twice, with -fsanitize=address and with -fsanitize=thread, and run
// with the fault DISABLED by default so the binary exits 0: linking and
// starting the runtime is what is under test here, not the diagnostics.
// Pass --fault to make it actually trip, which is how the harness proves the
// sanitizer is live rather than merely linked.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

int main(int argc, char **argv) {
  bool fault = false;
  for (int i = 1; i < argc; ++i)
    if (std::strcmp(argv[i], "--fault") == 0) fault = true;

#if defined(__has_feature)
#  if __has_feature(address_sanitizer)
  std::printf("address_sanitizer: ACTIVE\n");
#  elif __has_feature(thread_sanitizer)
  std::printf("thread_sanitizer: ACTIVE\n");
#  else
  std::printf("sanitizer: NONE DETECTED\n");
  // A build that was asked for a sanitizer and did not get one must not pass.
  return 2;
#  endif
#else
  std::printf("sanitizer: __has_feature unavailable\n");
  return 2;
#endif

  // Touch the heap so the runtime is genuinely initialised, not just linked.
  auto *buf = static_cast<char *>(std::malloc(32));
  if (!buf) return 3;
  std::memset(buf, 'a', 32);
  volatile char sink = buf[31];
  (void)sink;

  if (fault) {
    // Deliberate heap-buffer-overflow: ASan must abort here. Used by the
    // harness to prove the sanitizer is doing something, not just present.
    std::printf("faulting deliberately\n");
    std::fflush(stdout);
    volatile char boom = buf[64];
    (void)boom;
  }

  std::free(buf);
  std::printf("PASS\n");
  return 0;
}
