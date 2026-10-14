// One SYCL single_task, compiled and linked by the naga-acpp toolchain the way
// a downstream package does it. Exit 0 only if the kernel really ran.
#include <sycl/sycl.hpp>

#include <iostream>

int main() {
  sycl::queue q;
  int *result = sycl::malloc_shared<int>(1, q);
  *result = 0;

  q.single_task([=]() { *result = 42; }).wait();

  const int value = *result;
  sycl::free(result, q);

  std::cout << "acpp-consumer: kernel wrote " << value << " on "
            << q.get_device().get_info<sycl::info::device::name>() << "\n";
  return value == 42 ? 0 : 1;
}
