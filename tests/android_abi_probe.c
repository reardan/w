/* Optional device-side probe. Compile into an Android JNI test host and
 * call wandroid_abi_probe() after packaging libandroid_elf.so, compiled
 * from android_elf_fixture.w and android_elf_imports.w with --shared.
 * Returns zero on success; a numbered failure identifies the ABI case.
 */
#include <dlfcn.h>
#include <stdint.h>

typedef int64_t (*sum10_fn)(int64_t, int64_t, int64_t, int64_t, int64_t,
                          int64_t, int64_t, int64_t, int64_t, int64_t);
typedef float (*float_fn)(float, int64_t);
typedef double (*double9_fn)(double, double, double, double, double,
                            double, double, double, double);
typedef int64_t (*relocated_fn)(void);

int wandroid_abi_probe(void) {
    void *library = dlopen("libandroid_elf.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) return 1;
    sum10_fn sum10 = (sum10_fn)dlsym(library, "android_sum10");
    float_fn scale = (float_fn)dlsym(library, "android_float");
    double9_fn sum9 = (double9_fn)dlsym(library, "android_double");
    relocated_fn relocated = (relocated_fn)dlsym(library, "android_relocated");
    if (!sum10 || !scale || !sum9 || !relocated) return 2;
    if (sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) != 55) return 3;
    if (sum10(-1, -2, -3, -4, -5, -6, -7, -8, -9, -10) != -55) return 4;
    if (scale(1.5f, 4) != 6.0f) return 5;
    if (sum9(1, 2, 3, 4, 5, 6, 7, 8, 9) != 45.0) return 6;
    if (relocated() != 42) return 7;
    dlclose(library);
    return 0;
}
