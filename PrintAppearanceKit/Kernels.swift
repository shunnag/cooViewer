// GPU カーネルの Metal Shading Language ソース(設計書 §5)。実行時に makeLibrary(source:options:) でコンパイルする
// (.metal ファイルも metallib も置かない)。浮動小数点の規則: math_mode(safe) と fp contract(off) により、
// fma() と明示しない限り a*b+c は融合されず、Float の加算と乗算は Swift と同じに丸まる。

let metalSource = """
#include <metal_stdlib>
using namespace metal;
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)

struct PageInfo { int W; int H; int nx; int ny; };

inline float2 cmul(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
inline float2 cmulc(float2 a, float2 b) { return float2(a.x * b.x + a.y * b.y, a.y * b.x - a.x * b.y); } // a と b の共役の積
inline int mirrorIdx(int i, int n) { return i < 0 ? -i - 1 : (i >= n ? 2 * n - i - 1 : i); }
inline uint brev5(ushort L) { return reverse_bits((uint)L) >> 27; }

// 1 つの SIMD グループが持つ 128 点 FFT。レーン L のレジスタ r が要素 32r+L を持つ並び(natural)、
// またはレーン L のレジスタ k が要素 k + 4*brev5(L) を持つ並び(bitrev)。tw[m] = exp(-2 pi i m / 128)。
// 順変換 = レジスタ間の 4 点 DFT、回転因子 W128^(L k)、レーン間の 32 点基数 2 DIF。
inline void fftFwdN2B(thread float2 *v, ushort L, constant float2 *tw) {
    float2 t0 = v[0] + v[2], t1 = v[0] - v[2], t2 = v[1] + v[3], t3 = v[1] - v[3];
    float2 mt3 = float2(t3.y, -t3.x);
    v[0] = t0 + t2; v[2] = t0 - t2; v[1] = t1 + mt3; v[3] = t1 - mt3;
    v[1] = cmul(v[1], tw[L]); v[2] = cmul(v[2], tw[2 * L]); v[3] = cmul(v[3], tw[3 * L]);
    for (ushort h = 16; h >= 1; h >>= 1) {
        bool upper = (L & h) != 0;
        float2 w = tw[(L & (h - 1)) * (64 / h)];
        for (int k = 0; k < 4; k++) {
            float2 p = simd_shuffle_xor(v[k], h);
            v[k] = upper ? cmul(p - v[k], w) : v[k] + p;
        }
    }
}
// 逆変換(正規化なし、exp(+2 pi i ...))、bitrev 入力 → natural 出力。fftFwdN2B の網の正確な逆順。
inline void fftInvB2N(thread float2 *v, ushort L, constant float2 *tw) {
    for (ushort h = 1; h <= 16; h <<= 1) {
        bool upper = (L & h) != 0;
        float2 w = tw[(L & (h - 1)) * (64 / h)];
        for (int k = 0; k < 4; k++) {
            float2 p = simd_shuffle_xor(v[k], h);
            v[k] = upper ? p - cmulc(v[k], w) : v[k] + cmulc(p, w);
        }
    }
    v[1] = cmulc(v[1], tw[L]); v[2] = cmulc(v[2], tw[2 * L]); v[3] = cmulc(v[3], tw[3 * L]);
    float2 t0 = v[0] + v[2], t1 = v[0] - v[2], t2 = v[1] + v[3], t3 = v[1] - v[3];
    float2 it3 = float2(-t3.y, t3.x);
    v[0] = t0 + t2; v[2] = t0 - t2; v[1] = t1 + it3; v[3] = t1 - it3;
}
// 逆変換、natural 入力 → bitrev 出力(順変換と同じ構造で、回転因子は共役)。
inline void fftInvN2B(thread float2 *v, ushort L, constant float2 *tw) {
    float2 t0 = v[0] + v[2], t1 = v[0] - v[2], t2 = v[1] + v[3], t3 = v[1] - v[3];
    float2 it3 = float2(-t3.y, t3.x);
    v[0] = t0 + t2; v[2] = t0 - t2; v[1] = t1 + it3; v[3] = t1 - it3;
    v[1] = cmulc(v[1], tw[L]); v[2] = cmulc(v[2], tw[2 * L]); v[3] = cmulc(v[3], tw[3 * L]);
    for (ushort h = 16; h >= 1; h >>= 1) {
        bool upper = (L & h) != 0;
        float2 w = tw[(L & (h - 1)) * (64 / h)];
        for (int k = 0; k < 4; k++) {
            float2 p = simd_shuffle_xor(v[k], h);
            v[k] = upper ? cmulc(p - v[k], w) : v[k] + p;
        }
    }
}

// 各タイルの Float の逐次平均(走査順、鏡像の端処理)。CPU の和と同じ値になる。
kernel void tileMeans(device const float *lin [[buffer(0)]], constant PageInfo &pg [[buffer(1)]],
                      device float *means [[buffer(2)]], uint t [[thread_position_in_grid]]) {
    if (t >= uint(pg.nx * pg.ny)) return;
    int ox = -96 + 32 * int(t % uint(pg.nx)), oy = -96 + 32 * int(t / uint(pg.nx));
    float sum = 0;
    for (int y = 0; y < 128; y++) {
        device const float *row = lin + mirrorIdx(oy + y, pg.H) * pg.W;
        for (int x = 0; x < 128; x++) sum += row[mirrorIdx(ox + x, pg.W)];
    }
    means[t] = sum / 16384.0f;
}

// パス A: タイルの列 FFT。実数の 2 列を 1 つの複素 FFT に詰める。Z[slot][q][v]、q = 列の組。
// グリッド: スレッドグループ (4, slots)、各 16 SIMD グループ。
kernel void colFwd(device const float *lin [[buffer(0)]], constant PageInfo &pg [[buffer(1)]],
                   device const uint *tileList [[buffer(2)]], constant uint &listOffset [[buffer(3)]],
                   device const float *means [[buffer(4)]], constant float *hann [[buffer(5)]],
                   constant float2 *tw [[buffer(6)]], device float2 *Z [[buffer(7)]],
                   uint2 tg [[threadgroup_position_in_grid]], ushort sg [[simdgroup_index_in_threadgroup]],
                   ushort L [[thread_index_in_simdgroup]]) {
    uint slot = tg.y;
    uint t = tileList[listOffset + slot];
    int ox = -96 + 32 * int(t % uint(pg.nx)), oy = -96 + 32 * int(t / uint(pg.nx));
    uint q = tg.x * 16 + sg;
    int xa = 2 * int(q), xb = xa + 1;
    int mxa = mirrorIdx(ox + xa, pg.W), mxb = mirrorIdx(ox + xb, pg.W);
    float mean = means[t];
    float ha = hann[xa], hb = hann[xb];
    float2 v[4];
    for (int r = 0; r < 4; r++) {
        int y = 32 * r + L;
        device const float *row = lin + mirrorIdx(oy + y, pg.H) * pg.W;
        float hy = hann[y];
        float wa = hy * ha, wb = hy * hb;
        v[r] = float2((row[mxa] - mean) * wa, (row[mxb] - mean) * wb);
    }
    fftFwdN2B(v, L, tw);
    device float2 *dst = Z + size_t(slot) * 8192 + q * 128 + 4 * brev5(L);
    for (int k = 0; k < 4; k++) dst[k] = v[k];
}

// 詰めた列の組を分離する: x = 32r+L について A_x[v]。
inline void loadRow(device const float2 *Zs, uint v, ushort L, thread float2 *val) {
    uint vm = (128 - v) & 127;
    for (int r = 0; r < 4; r++) {
        uint x = 32 * r + L, q = x >> 1;
        float2 zp = Zs[q * 128 + v], zm = Zs[q * 128 + vm];
        float2 czm = float2(zm.x, -zm.y);
        if ((x & 1) == 0) val[r] = (zp + czm) * 0.5f;
        else { float2 d = zp - czm; val[r] = float2(d.y, -d.x) * 0.5f; }
    }
}

struct PrefilterParams { uint scanCount; uint words; float minPow3; float kRadial; float kBackground;
                         float tinyRing; float tinyThresh; };

// 候補の絞り込み(同じパワーに対して CPU の判定と完全に一致): pk > 0、3x3 の厳密な極大、s3 >= minPow3、
// 径方向の孤立、顕著さ。スレッド s = 走査の添字。候補のビット列は simd_ballot で走査順に作る。
// 顕著さは中央値そのものを使わずに判定する: med = 環の 56 値の昇順 28 番目のとき、
// Double(pk)/Double(med) >= kB  <=>  pk - kB*med >= 0(fma の符号は厳密)  <=>  環の値 v のうち 29 個以上で
// pk - kB*v >= 0。背景の下限 max(med, 1e-20) も 1e-20 に対する同じ数え方になる。
kernel void prefilterStencil(device const float *P [[buffer(0)]], device const int4 *scan [[buffer(1)]],
                             constant PrefilterParams &pp [[buffer(2)]], device uint *cand [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]], ushort L [[thread_index_in_simdgroup]]) {
    uint s = gid.x, slot = gid.y;
    bool pass = false;
    if (s < pp.scanCount) {
        int4 e = scan[s];
        device const float *Ps = P + size_t(slot) * 16384;
        float pk = Ps[((e.y & 127) << 7) | (e.x & 127)];
        if (pk > 0) {
            bool isMax = true;
            float s3 = 0;
            for (int dv = -1; dv <= 1; dv++) {
                int row = ((e.y + dv) & 127) << 7;
                for (int du = -1; du <= 1; du++) {
                    float q = Ps[row | ((e.x + du) & 127)];
                    s3 += q;
                    if (!(du == 0 && dv == 0) && q >= pk) isMax = false;
                }
            }
            if (isMax && s3 >= pp.minPow3) {
                float radial = Ps[e.z];
                if (e.w >= 0) radial = max(radial, Ps[e.w]);
                if (fma(-pp.kRadial, radial, pk) >= 0.0f) {          // Double(pk) >= kRadial * Double(radial) と同値
                    int below = 0, tiny = 0;
                    for (int dv = -4; dv <= 4; dv++) {
                        int row = ((e.y + dv) & 127) << 7;
                        for (int du = -4; du <= 4; du++) {
                            if (max(abs(du), abs(dv)) < 3) continue;
                            float q = Ps[row | ((e.x + du) & 127)];
                            below += fma(-pp.kBackground, q, pk) >= 0.0f ? 1 : 0;
                            tiny += q < pp.tinyRing ? 1 : 0;
                        }
                    }
                    pass = tiny >= 29 ? (pk >= pp.tinyThresh) : (below >= 29);
                }
            }
        }
    }
    uint vote = uint(uint64_t(simd_ballot(pass)));
    if (L == 0 && s / 32 < pp.words) cand[slot * pp.words + s / 32] = vote;
}

struct NotchTile { uint entryStart; uint entryCount; int nGuard; int pad; };
struct NotchEntry { float cxh; float cxl; float cyh; float cyl; int bu; int bv; int e; float flat;
                    float extent; float inv2s2; float omr; float pad; };

// パス B(パス 2): 行の順 FFT → ノッチの利得(ピーク順、次に符号順。保持率の下限つき)→ 差分スペクトル →
// 行の逆 FFT。S[slot][v][x](v = 0..64)へ書く。
// 行 v は SIMD グループで共通なので、項目の行の判定(|dv| <= e)はグループの全レーンで同じ答えになる。
// 各レーンが 32 項目のうち 1 つを調べて simd_ballot で集め、行が当たる項目だけを項目の順に読んで 4 ビンへ当てる
// (ビンごとに全項目の 48 バイトを読み直さない。ノッチの項目が多いページではこのカーネルが後段の大半を占める)。
// 各ビンに掛ける項目とその順番、Float の式はビンごとに全項目を調べる形と同じなので、利得はビット単位で変わらない。
// simd_ballot は 32 レーンを仮定する(GPUContext が Kernel.isSupported で実行幅 32 を確かめる)。
kernel void rowNotch(device const float2 *Z [[buffer(0)]], constant float2 *tw [[buffer(1)]],
                     device float2 *S [[buffer(2)]], device const NotchTile *tiles [[buffer(3)]],
                     constant uint &listOffset [[buffer(4)]], device const NotchEntry *entries [[buffer(5)]],
                     device const float *rbBySq [[buffer(6)]],
                     uint2 tg [[threadgroup_position_in_grid]], ushort sg [[simdgroup_index_in_threadgroup]],
                     ushort L [[thread_index_in_simdgroup]]) {
    uint slot = tg.y;
    uint v = tg.x * 13 + sg;
    float2 val[4];
    loadRow(Z + size_t(slot) * 8192, v, L, val);
    fftFwdN2B(val, L, tw);
    NotchTile nt = tiles[listOffset + slot];
    int sv = v < 64 ? int(v) : int(v) - 128;
    uint u0 = 4 * brev5(L);
    float g[4]; bool touched[4]; bool live[4]; int n2[4];
    for (int k = 0; k < 4; k++) {
        int u = int(u0) + k;
        int su = u < 64 ? u : u - 128;
        n2[k] = su * su + sv * sv;
        live[k] = n2[k] >= nt.nGuard;
        g[k] = 1.0f; touched[k] = false;
    }
    device const NotchEntry *ents = entries + nt.entryStart;
    // 項目の数はタイルごとに決まり、スレッドグループ内で共通: ループと simd_ballot はグループで揃って回る
    for (uint base = 0; base < nt.entryCount; base += 32) {
        uint jl = base + L;
        bool hit = false;
        if (jl < nt.entryCount) {
            int bv = ents[jl].bv, ee = ents[jl].e;
            int dvl = ((int(v) - bv + 64) & 127) - 64;
            hit = abs(dvl) <= ee;
        }
        uint mask = uint(uint64_t(simd_ballot(hit)));
        while (mask != 0) {
            uint b = ctz(mask);              // 項目の順(下位のビットから)
            mask &= mask - 1;
            NotchEntry en = ents[base + b];
            int dv = ((int(v) - en.bv + 64) & 127) - 64;
            float dy = (float(en.bv + dv) - en.cyh) - en.cyl;
            float dy2 = dy * dy;
            for (int k = 0; k < 4; k++) {
                if (!live[k]) continue;
                int u = int(u0) + k;
                int du = ((u - en.bu + 64) & 127) - 64;
                if (abs(du) > en.e) continue;
                float dx = (float(en.bu + du) - en.cxh) - en.cxl;
                float d = sqrt(dx * dx + dy2);
                if (d > en.extent) continue;
                float m = 1.0f;
                if (d > en.flat) { float t = d - en.flat; m = exp(-(t * t) * en.inv2s2); }
                g[k] *= 1.0f - en.omr * m;
                touched[k] = true;
            }
        }
    }
    for (int k = 0; k < 4; k++) {
        float gg = g[k];
        if (touched[k]) gg = max(gg, rbBySq[n2[k]]);
        float gm1 = gg - 1.0f;
        val[k] = float2(val[k].x * gm1, val[k].y * gm1);
    }
    fftInvB2N(val, L, tw);
    device float2 *Ss = S + size_t(slot) * 8320 + v * 128;
    for (int r = 0; r < 4; r++) Ss[32 * r + L] = val[r];
}

// パス C: 列の逆 FFT(実数 2 列を詰めたもの)。変化量に合成窓を掛けて delta に足す。1 回のディスパッチ内の
// タイルは重ならない((tx mod 4, ty mod 4) の位相が同じ)。グリッド: スレッドグループ (4, n)、各 16 SIMD グループ。
kernel void colInvScatter(device const float2 *S [[buffer(0)]], constant float2 *tw [[buffer(1)]],
                          constant PageInfo &pg [[buffer(2)]], device const uint *tileList [[buffer(3)]],
                          constant uint2 &range [[buffer(4)]], constant float *hann [[buffer(5)]],
                          device float *delta [[buffer(6)]],
                          uint2 tg [[threadgroup_position_in_grid]], ushort sg [[simdgroup_index_in_threadgroup]],
                          ushort L [[thread_index_in_simdgroup]]) {
    uint slot = range.y + tg.y;                    // チャンク内のスロット
    uint t = tileList[range.x + tg.y];             // 全体の並びの位置 → タイル番号
    int ox = -96 + 32 * int(t % uint(pg.nx)), oy = -96 + 32 * int(t / uint(pg.nx));
    uint q = tg.x * 16 + sg;
    int xa = 2 * int(q), xb = xa + 1;
    device const float2 *Ss = S + size_t(slot) * 8320;
    float2 val[4];
    for (int r = 0; r < 4; r++) {
        uint v = 32 * r + L;
        float2 sa, sb;
        if (v <= 64) {
            sa = Ss[v * 128 + xa]; sb = Ss[v * 128 + xb];
            if (v == 0 || v == 64) { sa.y = 0; sb.y = 0; }
        } else {
            uint vm = 128 - v;
            sa = Ss[vm * 128 + xa]; sb = Ss[vm * 128 + xb];
            sa.y = -sa.y; sb.y = -sb.y;
        }
        val[r] = float2(sa.x - sb.y, sa.y + sb.x);
    }
    fftInvN2B(val, L, tw);
    int X = ox + xa;
    bool okA = X >= 0 && X < pg.W, okB = X + 1 >= 0 && X + 1 < pg.W;
    float ha = hann[xa], hb = hann[xb];
    uint y0 = 4 * brev5(L);
    const float scale = 1.0f / 16384.0f;
    for (int k = 0; k < 4; k++) {
        int y = int(y0) + k;
        int Y = oy + y;
        if (Y < 0 || Y >= pg.H) continue;
        float hy = hann[y];
        device float *row = delta + Y * pg.W + X;
        if (okA) { float c = val[k].x * scale; row[0] += c * (hy * ha); }
        if (okB) { float c = val[k].y * scale; row[1] += c * (hy * hb); }
    }
}

kernel void fillZero(device float *a [[buffer(0)]], constant uint &count [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) { if (i < count) a[i] = 0; }

// wsum(32x32 の周期模様)で delta != 0 の画素を割る。d2 = delta^2。
kernel void normalise(device float *delta [[buffer(0)]], device float *d2 [[buffer(1)]],
                      constant float *wsum [[buffer(2)]], constant PageInfo &pg [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= pg.W || int(gid.y) >= pg.H) return;
    uint i = gid.y * pg.W + gid.x;
    float d = delta[i];
    if (d != 0) { d = d / wsum[(gid.y & 31) * 32 + (gid.x & 31)]; delta[i] = d; }
    d2[i] = d * d;
}

// 分離型ガウスぼかし、端は延長(vImage の kvImageEdgeExtend と同じ)。dir 0 = 横、1 = 縦。
kernel void blur(device const float *src [[buffer(0)]], device float *dst [[buffer(1)]],
                 constant float *taps [[buffer(2)]], constant int2 &rd [[buffer(3)]],
                 constant PageInfo &pg [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= pg.W || y >= pg.H) return;
    int r = rd.x;
    float s = 0;
    if (rd.y == 0) {
        device const float *row = src + y * pg.W;
        for (int i = -r; i <= r; i++) s += taps[i + r] * row[clamp(x + i, 0, pg.W - 1)];
    } else {
        for (int i = -r; i <= r; i++) s += taps[i + r] * src[clamp(y + i, 0, pg.H - 1) * pg.W + x];
    }
    dst[y * pg.W + x] = s;
}

kernel void highpassSq(device const float *lin [[buffer(0)]], device float *a [[buffer(1)]],
                       constant uint &count [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < count) { float h = lin[i] - a[i]; a[i] = h * h; }
}

// q3 エッジクランプ(前半): 画素ごとに、その画素を含む 3x3 窓のうち最も平らなものの符号値の範囲 [lo, hi]。
// 窓は左上を (x - ox, y - oy)(ox, oy は 0..2、y が外側・x が内側、0 で打ち切り)に置き、
// (min(W-1, ax + dx), min(H-1, ay + dy)) まで広がる。平らさは enc[src] の hi - lo
// (enc = encodeByte(eotf[v]) は lin を符号化し直した値)。同点は先の窓を残す(厳密な <)。
// 整数だけなので CPU の実装とビット単位で一致する。src だけに依存するので、GPU の前段としてパス 1 の後に積み、
// 近傍の一致と A2 の間に走らせる(Descreener.commitFrontWork)。
kernel void q3Window(device const uchar *src [[buffer(0)]], device uchar2 *bounds [[buffer(1)]],
                     constant uchar *enc [[buffer(2)]], constant PageInfo &pg [[buffer(3)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= pg.W || y >= pg.H) return;
    int bestR = 256;
    uchar lo = 0, hi = 255;
    for (int oy = 0; oy < 3; oy++) {
        int ay = max(0, y - oy);
        for (int ox = 0; ox < 3; ox++) {
            int ax = max(0, x - ox);
            uchar a = 255, b = 0;
            for (int dy = 0; dy < 3; dy++) {
                device const uchar *row = src + min(pg.H - 1, ay + dy) * pg.W;
                for (int dx = 0; dx < 3; dx++) {
                    uchar q = enc[row[min(pg.W - 1, ax + dx)]];
                    a = min(a, q); b = max(b, q);
                }
            }
            int r = int(b) - int(a);
            if (r < bestR) { bestR = r; lo = a; hi = b; }
        }
    }
    bounds[y * pg.W + x] = uchar2(lo, hi);
}

// エネルギーゲート + q3(後半)+ 再符号化。順序: ゲート。次にゲート後の d != 0 の画素で v = lin + d、
// c = min(h, max(l, v))(l = eotf[lo]、h = eotf[hi])。c != v なら d = c - lin(触れた画素)。
// 最後に d != 0 の画素で raw = lin + d の範囲外を数え、再符号化する。出力の符号値は raw 以下のしきい値の個数
// (CPU の oetf255 の丸めと厳密に一致)。
kernel void gateEncodeQ3(device const float *lin [[buffer(0)]], device float *delta [[buffer(1)]],
                         device const float *ex [[buffer(2)]], device const float *ed [[buffer(3)]],
                         device const uchar *src [[buffer(4)]], device uchar *outb [[buffer(5)]],
                         constant float *thr [[buffer(6)]], device atomic_uint *counters [[buffer(7)]],
                         constant uint &count [[buffer(8)]], device const uchar2 *bounds [[buffer(9)]],
                         constant float *eotf [[buffer(10)]], uint i [[thread_position_in_grid]]) {
    bool clamped = false, changed = false, touched = false;
    if (i < count) {
        float d = delta[i];
        uchar o = src[i];
        if (d != 0) {
            float e = ed[i];
            float g = e > 1e-12f ? min(1.0f, sqrt(ex[i] / e)) : 1.0f;
            d = d * g;
            if (d != 0) {
                uchar2 bd = bounds[i];
                float l = eotf[bd.x], h = eotf[bd.y];
                float v = lin[i] + d;
                float c = min(h, max(l, v));
                if (c != v) { d = c - lin[i]; touched = true; }
            }
            delta[i] = d;
            if (d != 0) {
                float raw = lin[i] + d;
                clamped = raw < 0.0f || raw > 1.0f;
                int b = int(o);
                while (b < 255 && raw >= thr[b + 1]) b++;
                while (b > 0 && raw < thr[b]) b--;
                o = uchar(b);
            }
        }
        changed = o != src[i];
        outb[i] = o;
    }
    uint nc = simd_sum(clamped ? 1u : 0u), nch = simd_sum(changed ? 1u : 0u), nt = simd_sum(touched ? 1u : 0u);
    if (simd_is_first()) {
        if (nc) atomic_fetch_add_explicit(&counters[0], nc, memory_order_relaxed);
        if (nch) atomic_fetch_add_explicit(&counters[1], nch, memory_order_relaxed);
        if (nt) atomic_fetch_add_explicit(&counters[2], nt, memory_order_relaxed);
    }
}
"""
