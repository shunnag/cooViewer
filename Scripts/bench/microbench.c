// CRC-32 と inflate の実装比較マイクロベンチマーク(フレームワーク非依存)。
// 対象: (a) XADMaster のテーブル CRC(1 バイト/8 バイトスライス)を模した実装
//       (b) ARMv8 ハードウェア crc32 命令
//       (c) Apple システム zlib の crc32()
//       (d) inflate: zlib ストリーム(16KB/256KB チャンク) vs libcompression vs libdeflate
// データ: 乱数 64MB(JPEG 本相当の非圧縮性)と、網点調の圧縮性 64MB。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>
#include <compression.h>
#include <arm_acle.h>
#include <libdeflate.h>

static double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

// ---- XADMaster と同じ構成のテーブル CRC(edb88320) ----
static uint32_t table1[256];
static uint32_t table16[16][256];
static void build_tables(void) {
    for (int n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (c & 1 ? 0xedb88320u : 0);
        table1[n] = c;
    }
    for (int n = 0; n < 256; n++) {
        table16[0][n] = table1[n];
        for (int s = 1; s < 16; s++)
            table16[s][n] = (table16[s-1][n] >> 8) ^ table1[table16[s-1][n] & 0xff];
    }
}
static uint32_t crc_table1(uint32_t crc, const uint8_t *p, size_t len) {
    for (size_t i = 0; i < len; i++) crc = (crc >> 8) ^ table1[(crc ^ p[i]) & 0xff];
    return crc;
}
// XADCalculateCRCFast 相当(sliced-by-16)
static uint32_t crc_sliced16(uint32_t crc, const uint8_t *p, size_t len) {
    while (len && ((uintptr_t)p & 15)) { crc = (crc >> 8) ^ table1[(crc ^ *p++) & 0xff]; len--; }
    while (len >= 16) {
        uint32_t a = *(const uint32_t *)p ^ crc;
        uint32_t b = *(const uint32_t *)(p + 4);
        uint32_t c = *(const uint32_t *)(p + 8);
        uint32_t d = *(const uint32_t *)(p + 12);
        crc = table16[15][a & 0xff] ^ table16[14][(a >> 8) & 0xff]
            ^ table16[13][(a >> 16) & 0xff] ^ table16[12][a >> 24]
            ^ table16[11][b & 0xff] ^ table16[10][(b >> 8) & 0xff]
            ^ table16[9][(b >> 16) & 0xff] ^ table16[8][b >> 24]
            ^ table16[7][c & 0xff] ^ table16[6][(c >> 8) & 0xff]
            ^ table16[5][(c >> 16) & 0xff] ^ table16[4][c >> 24]
            ^ table16[3][d & 0xff] ^ table16[2][(d >> 8) & 0xff]
            ^ table16[1][(d >> 16) & 0xff] ^ table16[0][d >> 24];
        p += 16; len -= 16;
    }
    while (len--) crc = (crc >> 8) ^ table1[(crc ^ *p++) & 0xff];
    return crc;
}
// ARMv8 CRC32 命令(8 バイト/命令)
static uint32_t crc_hw(uint32_t crc, const uint8_t *p, size_t len) {
    while (len && ((uintptr_t)p & 7)) { crc = __crc32b(crc, *p++); len--; }
    while (len >= 8) { crc = __crc32d(crc, *(const uint64_t *)p); p += 8; len -= 8; }
    while (len--) crc = __crc32b(crc, *p++);
    return crc;
}

// 呼び出しを前結果に連鎖させ、ループ不変の畳み込み(同一引数の純関数化)を防ぐ
static void bench_crc(const char *label, const uint8_t *buf, size_t len) {
    build_tables();
    double t;
    uint32_t r1 = crc_table1(0xffffffff, buf, len) ^ 0xffffffff;
    uint32_t r2 = crc_sliced16(0xffffffff, buf, len) ^ 0xffffffff;
    uint32_t r3 = crc_hw(0xffffffff, buf, len) ^ 0xffffffff;
    uint32_t r4 = (uint32_t)crc32(0, buf, (uInt)len);
    if (r1 != r2 || r1 != r3 || r1 != r4) { printf("CRC MISMATCH %08x %08x %08x %08x\n", r1, r2, r3, r4); exit(1); }
    t = now_ms(); for (int i = 0; i < 3; i++) r1 = crc_table1(r1, buf, len); t = now_ms() - t;
    printf("%s crc_table1    %10.0f MB/s\n", label, 3 * len / t / 1e3);
    t = now_ms(); for (int i = 0; i < 10; i++) r2 = crc_sliced16(r2, buf, len); t = now_ms() - t;
    printf("%s crc_sliced16  %10.0f MB/s\n", label, 10 * len / t / 1e3);
    t = now_ms(); for (int i = 0; i < 30; i++) r3 = crc_hw(r3, buf, len); t = now_ms() - t;
    printf("%s crc_hw        %10.0f MB/s\n", label, 30 * len / t / 1e3);
    t = now_ms(); for (int i = 0; i < 30; i++) r4 = (uint32_t)crc32(r4, buf, (uInt)len); t = now_ms() - t;
    printf("%s crc_zlib      %10.0f MB/s\n", label, 30 * len / t / 1e3);
    if ((r1 ^ r2 ^ r3 ^ r4) == 0xdeadbeef) printf("(sink %u)\n", r1);  // 除去防止
}

// ---- inflate 比較 ----
static uint8_t *deflate_buf(const uint8_t *src, size_t len, size_t *outlen, int raw) {
    uLongf bound = compressBound(len) + 64;
    uint8_t *dst = malloc(bound);
    z_stream zs = {0};
    deflateInit2(&zs, 6, Z_DEFLATED, raw ? -15 : 15, 8, Z_DEFAULT_STRATEGY);
    zs.next_in = (Bytef *)src; zs.avail_in = (uInt)len;
    zs.next_out = dst; zs.avail_out = (uInt)bound;
    deflate(&zs, Z_FINISH);
    *outlen = zs.total_out;
    deflateEnd(&zs);
    return dst;
}
static double bench_zlib_stream(const uint8_t *comp, size_t clen, uint8_t *out, size_t olen, size_t chunk, int reps) {
    double t = now_ms();
    for (int r = 0; r < reps; r++) {
        z_stream zs = {0};
        inflateInit2(&zs, -15);
        size_t pos = 0, opos = 0;
        while (pos < clen && opos < olen) {
            size_t in_n = clen - pos < chunk ? clen - pos : chunk;
            zs.next_in = (Bytef *)(comp + pos); zs.avail_in = (uInt)in_n;
            while (zs.avail_in && opos < olen) {
                size_t out_n = olen - opos < chunk ? olen - opos : chunk;
                zs.next_out = out + opos; zs.avail_out = (uInt)out_n;
                int err = inflate(&zs, 0);
                opos = zs.total_out;
                if (err == Z_STREAM_END) goto done;
                if (err != Z_OK && err != Z_BUF_ERROR) { printf("zlib err %d\n", err); exit(1); }
            }
            pos += in_n - zs.avail_in;
        }
    done:
        inflateEnd(&zs);
    }
    return now_ms() - t;
}
static double bench_libcompression(const uint8_t *comp, size_t clen, uint8_t *out, size_t olen, size_t chunk, int reps) {
    double t = now_ms();
    for (int r = 0; r < reps; r++) {
        compression_stream cs;
        compression_stream_init(&cs, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB);
        cs.src_ptr = comp; cs.src_size = clen;
        size_t opos = 0;
        while (opos < olen) {
            size_t out_n = olen - opos < chunk ? olen - opos : chunk;
            cs.dst_ptr = out + opos; cs.dst_size = out_n;
            compression_status st = compression_stream_process(&cs, cs.src_size ? 0 : COMPRESSION_STREAM_FINALIZE);
            opos += out_n - cs.dst_size;
            if (st == COMPRESSION_STATUS_END) break;
            if (st == COMPRESSION_STATUS_ERROR) { printf("libcompression err\n"); exit(1); }
        }
        compression_stream_destroy(&cs);
    }
    return now_ms() - t;
}
static double bench_libdeflate(const uint8_t *comp, size_t clen, uint8_t *out, size_t olen, int reps) {
    double t = now_ms();
    for (int r = 0; r < reps; r++) {
        struct libdeflate_decompressor *d = libdeflate_alloc_decompressor();
        size_t actual;
        enum libdeflate_result res = libdeflate_deflate_decompress(d, comp, clen, out, olen, &actual);
        if (res != LIBDEFLATE_SUCCESS || actual != olen) { printf("libdeflate err %d\n", res); exit(1); }
        libdeflate_free_decompressor(d);
    }
    return now_ms() - t;
}

static void bench_inflate(const char *label, const uint8_t *src, size_t len) {
    size_t clen;
    uint8_t *comp = deflate_buf(src, len, &clen, 1);
    uint8_t *out = malloc(len);
    int reps = 6;
    printf("%s (deflate 済み %.1f MB, 比率 %.2f)\n", label, clen / 1e6, (double)clen / len);
    double t;
    t = bench_zlib_stream(comp, clen, out, len, 0x4000, reps);
    if (memcmp(out, src, len)) { printf("zlib16 MISMATCH\n"); exit(1); }
    printf("%s inflate zlib-16KB     %8.1f MB/s(出力換算)\n", label, reps * len / t / 1e3);
    t = bench_zlib_stream(comp, clen, out, len, 0x40000, reps);
    printf("%s inflate zlib-256KB    %8.1f MB/s\n", label, reps * len / t / 1e3);
    t = bench_libcompression(comp, clen, out, len, 0x40000, reps);
    if (memcmp(out, src, len)) { printf("libcompression MISMATCH\n"); exit(1); }
    printf("%s inflate libcompression%8.1f MB/s\n", label, reps * len / t / 1e3);
    t = bench_libdeflate(comp, clen, out, len, reps);
    if (memcmp(out, src, len)) { printf("libdeflate MISMATCH\n"); exit(1); }
    printf("%s inflate libdeflate    %8.1f MB/s\n", label, reps * len / t / 1e3);
    free(comp); free(out);
}

// 実データファイル(JPEG 連結 / TIFF 連結)を読み込んで使う
static uint8_t *load_file(const char *path, size_t cap, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("open %s failed\n", path); exit(1); }
    uint8_t *buf = malloc(cap);
    *outlen = fread(buf, 1, cap, f);
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: microbench <jpeg.bin> <tiff.bin>\n"); return 2; }
    size_t CAP = 64u << 20, jl, tl;
    uint8_t *jpeg = load_file(argv[1], CAP, &jl);
    uint8_t *tiff = load_file(argv[2], CAP, &tl);
    printf("== CRC-32(実 JPEG %.0f MB)==\n", jl / 1e6);
    bench_crc("jpeg", jpeg, jl);
    printf("== inflate 実 JPEG(cbz の中身相当)==\n");
    bench_inflate("jpeg", jpeg, jl);
    printf("== inflate 実 TIFF(高圧縮性)==\n");
    bench_inflate("tiff", tiff, tl);
    free(jpeg); free(tiff);
    return 0;
}
