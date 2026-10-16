#if defined(WASP_SIMD_VT_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef WASP_SIMD_VT_H_
#undef WASP_SIMD_VT_H_
#else
#define WASP_SIMD_VT_H_
#endif

#include <hwy/highway.h>

HWY_BEFORE_NAMESPACE();
namespace wasp {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

}  // namespace HWY_NAMESPACE
}  // namespace wasp
HWY_AFTER_NAMESPACE();

#if HWY_ONCE

namespace wasp {

typedef void (*PrintFunc)(const char32_t* chars, size_t count);

}  // namespace wasp

#endif  // HWY_ONCE

#endif  // WASP_SIMD_VT_H_
