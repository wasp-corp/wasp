#include <wasp/vt.h>
#include <stdio.h>
int main(void) {
    bool simd = false;
    WaspResult r = wasp_build_info(WASP_BUILD_INFO_SIMD, &simd);
    if (r != WASP_SUCCESS) return 1;
    printf("SIMD: %s\n", simd ? "yes" : "no");
    return 0;
}
