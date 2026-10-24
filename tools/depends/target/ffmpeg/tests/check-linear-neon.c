/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if !defined(__aarch64__)
#error Run this numerical/cadence test on AArch64.
#endif
/* These are precisely the fields the unmodified FFmpeg template accesses.
 * Both complete kernels below come from the actual dependency source. */
typedef struct {
    uint8_t *filter_bank;
    int filter_length, filter_alloc, index, frac, src_incr;
    int dst_incr_mod, dst_incr_div, phase_count;
} ResampleContext;
#define ARCH_AARCH64 1
#define HAVE_NEON 1
#define TEMPLATE_RESAMPLE_FLT
#include "reference.c"
#include "candidate.c"
#undef TEMPLATE_RESAMPLE_FLT
static uint32_t seed = 0x61a045;
static float random_sample(void) {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (float)((double)seed / UINT32_MAX * 2.0 - 1.0);
}
static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
int main(int argc, char **argv) {
    const int lengths[] = {1,2,3,4,5,7,8,15,32,64,65,256};
    const int phases[] = {1,7,32,1024};
    const int n = 257;
    double error2 = 0, signal2 = 0, max_error = 0;
    unsigned long samples = 0;
    for (int l = 0; l < 12; ++l) for (int p = 0; p < 4; ++p) {
        int length = lengths[l], phase = phases[p];
        float *filter = malloc((phase + 1) * length * sizeof(float));
        float *input = malloc((n * 3 + length + 3) * sizeof(float));
        float *a = malloc(n * sizeof(float)), *b = malloc(n * sizeof(float));
        for (int j = 0; j <= phase; ++j) {
            double norm = 0;
            for (int i = 0; i < length; ++i) {
                filter[j * length + i] = random_sample();
                norm += fabs(filter[j * length + i]);
            }
            for (int i = 0; i < length; ++i) filter[j * length + i] *= 2.0 / norm;
        }
        for (int kind = 0; kind < 5; ++kind) for (int t = 0; t < 16; ++t) for (int update = 0; update < 2; ++update) {
            for (int i = 0; i < n * 3 + length + 3; ++i)
                input[i] = kind == 0 ? random_sample() : kind == 1 ? sin(i * 2.61799387799) :
                           kind == 2 ? (i == length) : kind == 3 ? 0 : random_sample() * 1e-20f;
            ResampleContext ca = {(uint8_t*)filter, length, length, (t % 3) * phase + phase - 1,
                (t * 65413) % 1000003, 1000003, (t * 49663) % 1000003, phase, phase};
            ResampleContext cb = ca;
            int consumed_a = resample_linear_reference(&ca, a, input, n, update);
            int consumed_b = resample_linear_float(&cb, b, input, n, update);
            assert(consumed_a == consumed_b && ca.index == cb.index && ca.frac == cb.frac);
            for (int i = 0; i < n; ++i) {
                double e = a[i] - b[i];
                assert(isfinite(b[i]) && fabs(e) <= 3e-6);
                error2 += e * e; signal2 += a[i] * a[i];
                if (fabs(e) > max_error) max_error = fabs(e);
                ++samples;
            }
        }
        free(a); free(b); free(input); free(filter);
    }
    double snr = 10.0 * log10(signal2 / error2);
    assert(snr > 120.0);
    printf("%s: %lu samples; identical consumed samples/index/phase; max error %.9g; SNR %.2f dB\n", argv[1], samples, max_error, snr);
    if (strcmp(argv[1], "optimized") == 0) {
        float filter[65 * 64], input[2048], output[1024];
        for (int i = 0; i < 65 * 64; ++i) filter[i] = random_sample() / 64;
        for (int i = 0; i < 2048; ++i) input[i] = random_sample();
        volatile double checksum = 0;
        ResampleContext c = {(uint8_t*)filter, 64, 64, 0, 123456, 1000003, 500003, 64, 64};
        double start = now();
        for (int j = 0; j < 3000; ++j) {
            resample_linear_reference(&c, output, input, 1024, 0);
            checksum += output[j % 1024];
        }
        double scalar = now() - start;
        start = now();
        for (int j = 0; j < 3000; ++j) {
            resample_linear_float(&c, output, input, 1024, 0);
            checksum += output[j % 1024];
        }
        double neon = now() - start;
        printf("kernel benchmark: scalar %.4fs; NEON %.4fs; speedup %.2fx; checksum %.9g\n", scalar, neon, scalar / neon, checksum);
    }
    return 0;
}
