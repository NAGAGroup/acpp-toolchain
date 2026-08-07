// SYCL smoke test: generic SSCP target, runs on any backend (CPU always).
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
  sycl::queue q{sycl::default_selector_v};
  std::printf("device: %s\n",
              q.get_device().get_info<sycl::info::device::name>().c_str());
  constexpr size_t N = 1024;
  std::vector<int> data(N, 1);
  {
    int* d = sycl::malloc_device<int>(N, q);
    q.memcpy(d, data.data(), N * sizeof(int)).wait();
    q.parallel_for(sycl::range<1>{N}, [=](sycl::id<1> i) { d[i] += static_cast<int>(i[0]); }).wait();
    q.memcpy(data.data(), d, N * sizeof(int)).wait();
    sycl::free(d, q);
  }
  for (size_t i = 0; i < N; ++i) {
    if (data[i] != 1 + static_cast<int>(i)) { std::printf("FAIL at %zu\n", i); return 1; }
  }
  std::printf("PASS\n");
  return 0;
}
