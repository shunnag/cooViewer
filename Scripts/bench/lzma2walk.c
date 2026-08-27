// LZMA2 チャンクヘッダ・ウォーカー(dic-reset 点の実態調査。復号はしない)。
// 使い方: lzma2walk <7zfile>
// 単一フォルダ・単一コーダ(LZMA2)の 7z を前提に、packed ストリーム(署名ヘッダ
// 直後=オフセット 0x20)を先頭からチャンクヘッダだけ辿る。各 dic-reset 点の
// (出力オフセット, packed オフセット)を数える。壊れ/想定外は即中断(索引破棄相当)。
//
// LZMA2 チャンク文法:
//   control==0x00              → ストリーム終端
//   control==0x01 or 0x02      → 非圧縮チャンク。2 バイト BE の (サイズ-1)、続いて生データ。
//                                0x01 は dict リセット点
//   control>=0x80              → LZMA チャンク。
//                                unpacked = ((control&0x1f)<<16) + (2 バイト BE)+1
//                                packed   = (2 バイト BE)+1
//                                resetmode= (control>>5)&3
//                                resetmode>=2 のとき props 1 バイトが続く
//                                resetmode==3 が dict リセット点
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <7zfile>\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END);
    long filesize = ftell(f);
    fseek(f, 0x20, SEEK_SET);  // packed ストリーム開始(単一フォルダ 7z)
    long packedbase = 0x20;

    long packedpos = 0;      // packed ストリーム内の相対オフセット
    uint64_t outputpos = 0;  // 展開後の出力オフセット
    int chunks = 0, resets = 0, lzmachunks = 0, uncompchunks = 0;
    uint64_t firstresetout = 0, lastresetout = 0;
    int printed = 0;

    for (;;) {
        int control = fgetc(f);
        if (control == EOF) { printf("EOF(no 0x00 terminator)\n"); break; }
        if (control == 0x00) {
            printf("STREAM END at packed=%ld output=%llu\n", packedpos, (unsigned long long)outputpos);
            break;
        }
        chunks++;
        long chunkheaderpacked = packedpos;
        packedpos++;  // control byte

        if (control == 0x01 || control == 0x02) {
            int hi = fgetc(f), lo = fgetc(f);
            if (hi == EOF || lo == EOF) { printf("TRUNCATED uncompressed header\n"); break; }
            long size = ((hi << 8) | lo) + 1;
            packedpos += 2;
            int isreset = (control == 0x01);
            uncompchunks++;
            if (isreset) {
                if (resets == 0) firstresetout = outputpos;
                lastresetout = outputpos;
                resets++;
                if (printed < 8) { printf("  reset(uncomp) #%d out=%llu packed=%ld\n", resets, (unsigned long long)outputpos, packedbase + chunkheaderpacked); printed++; }
            }
            if (fseek(f, size, SEEK_CUR) != 0) { printf("SEEK past data failed\n"); break; }
            packedpos += size;
            outputpos += size;
        } else if (control >= 0x80) {
            int u1 = fgetc(f), u2 = fgetc(f), p1 = fgetc(f), p2 = fgetc(f);
            if (u1 == EOF || u2 == EOF || p1 == EOF || p2 == EOF) { printf("TRUNCATED lzma header\n"); break; }
            long unpacked = ((long)(control & 0x1f) << 16) + ((u1 << 8) | u2) + 1;
            long packed = ((p1 << 8) | p2) + 1;
            int resetmode = (control >> 5) & 3;
            packedpos += 4;
            lzmachunks++;
            if (resetmode >= 2) {
                if (fgetc(f) == EOF) { printf("TRUNCATED props byte\n"); break; }
                packedpos += 1;  // props byte
            }
            if (resetmode == 3) {
                if (resets == 0) firstresetout = outputpos;
                lastresetout = outputpos;
                resets++;
                if (printed < 8) { printf("  reset(lzma3) #%d out=%llu packed=%ld\n", resets, (unsigned long long)outputpos, packedbase + chunkheaderpacked); printed++; }
            }
            if (fseek(f, packed, SEEK_CUR) != 0) { printf("SEEK past data failed\n"); break; }
            packedpos += packed;
            outputpos += unpacked;
        } else {
            printf("UNKNOWN control 0x%02x at packed=%ld\n", control, packedpos - 1);
            break;
        }
        // 病的サイズガード
        if (packedbase + packedpos > filesize + 64) { printf("OVERRAN file\n"); break; }
    }

    printf("== %s ==\n", argv[1]);
    printf("chunks=%d (lzma=%d uncomp=%d) reset-points=%d output-bytes=%llu\n",
           chunks, lzmachunks, uncompchunks, resets, (unsigned long long)outputpos);
    if (resets > 1)
        printf("reset spacing: first-out=%llu last-out=%llu avg=%llu bytes\n",
               (unsigned long long)firstresetout, (unsigned long long)lastresetout,
               (unsigned long long)(outputpos / (resets ? resets : 1)));
    fclose(f);
    return 0;
}
