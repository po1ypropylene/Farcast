#include <freerdp/codec/color.h>
#include <freerdp/codec/h264.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    H264_CONTEXT *encoder = h264_context_new(TRUE), *decoder = h264_context_new(FALSE);
    if (!encoder || !decoder) {
        fputs("FAIL H.264 backend initialization\n", stderr);
        return 1;
    }
    const int widths[] = {320, 1440};
    const int heights[] = {240, 900};
    for (int size = 0; size < 2; size++) {
        int w = widths[size], h = heights[size];
        BYTE *input = calloc((size_t)w * h, 4), *output = calloc((size_t)w * h, 4);
        if (!input || !output || !h264_context_reset(encoder, w, h) || !h264_context_reset(decoder, w, h))
            return 2;
        for (int i = 0; i < w * h; i++) {
            BYTE value = (((i % w) / 32 + (i / w) / 32) % 2) * 100 + 64;
            input[i * 4] = input[i * 4 + 1] = input[i * 4 + 2] = value;
            input[i * 4 + 3] = 255;
        }
        BYTE *compressed = NULL;
        UINT32 count = 0;
        RECTANGLE_16 region = {0, 0, (UINT16)w, (UINT16)h};
        RDPGFX_H264_METABLOCK meta = {0};
        int encoded =
            avc420_compress(encoder, input, PIXEL_FORMAT_BGRA32, w * 4, w, h, &region, &compressed, &count, &meta);
        int decoded = encoded >= 0 && count ? avc420_decompress(decoder, compressed, count, output, PIXEL_FORMAT_BGRA32,
                                                                w * 4, w, h, &region, 1)
                                            : -1;
        double error = 0;
        for (int i = 0; i < w * h; i++)
            error += abs((int)input[i * 4] - (int)output[i * 4]);
        error /= w * h;
        if (decoded < 0 || error > 10) {
            fprintf(stderr, "FAIL AVC420 roundtrip encode=%d decode=%d error=%.2f\n", encoded, decoded, error);
            return 3;
        }
        printf("PASS source-built H.264 AVC420 %dx%d roundtrip (%u bytes, mean channel error %.2f)\n", w, h, count,
               error);
        free_h264_metablock(&meta);
        for (BYTE version = 1; version <= 2; version++) {
            // Each codec version starts a separate stream, not an unchanged
            // inter-frame update from the previous codec's encoder history.
            h264_context_free(encoder);
            h264_context_free(decoder);
            encoder = h264_context_new(TRUE);
            decoder = h264_context_new(FALSE);
            if (!encoder || !decoder)
                return 4;
            if (!h264_context_reset(encoder, w, h) || !h264_context_reset(decoder, w, h))
                return 4;
            BYTE op = 0, *aux = NULL;
            UINT32 auxCount = 0;
            compressed = NULL;
            count = 0;
            memset(output, 0, (size_t)w * h * 4);
            RDPGFX_H264_METABLOCK mainMeta = {0}, auxMeta = {0};
            encoded = avc444_compress(encoder, input, PIXEL_FORMAT_BGRA32, w * 4, w, h, version, &region, &op,
                                      &compressed, &count, &aux, &auxCount, &mainMeta, &auxMeta);
            decoded = encoded >= 0 && count
                          ? avc444_decompress(decoder, op, &region, 1, compressed, count, &region, 1, aux, auxCount,
                                              output, PIXEL_FORMAT_BGRA32, w * 4, w, h,
                                              version == 1 ? RDPGFX_CODECID_AVC444 : RDPGFX_CODECID_AVC444v2)
                          : -1;
            error = 0;
            for (int i = 0; i < w * h; i++)
                for (int channel = 0; channel < 3; channel++)
                    error += abs((int)input[i * 4 + channel] - (int)output[i * 4 + channel]);
            error /= w * h * 3;
            if (decoded < 0 || error > 10) {
                fprintf(stderr, "FAIL AVC444v%u encode=%d decode=%d error=%.2f\n", version, encoded, decoded, error);
                return 5;
            }
            printf("PASS source-built H.264 AVC444v%u %dx%d roundtrip (mean channel error %.2f)\n", version, w, h,
                   error);
            free_h264_metablock(&mainMeta);
            free_h264_metablock(&auxMeta);
        }
        free(input);
        free(output);
    }
    h264_context_free(encoder);
    h264_context_free(decoder);
    return 0;
}
