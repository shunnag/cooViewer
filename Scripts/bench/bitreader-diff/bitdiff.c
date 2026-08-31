// CSInputBuffer ビットリーダの差分ハーネス。
// OLD(32bit レザバー、現行実装をそのまま移植)と NEW(64bit レザバー)を
// 同一バイト列・同一 op 列で並走させ、各 op 後の返り値・BufferOffset・BitOffset を
// 突き合わせる。メモリ背景モード(parent=NULL, eof=YES)で CSHandle 非依存。
// 相違が 1 つでもあれば FATAL。数百万 op を乱数シードで回す。
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <setjmp.h>

// ---- 共通の EOF 機構(例外の代わりに longjmp)----
static jmp_buf eofenv;
#define RAISE_EOF() longjmp(eofenv, 1)

// ================= OLD(32bit)=================
typedef struct {
    int64_t startoffs;
    int eof;
    const uint8_t *buffer;
    unsigned int bufsize, bufbytes, currbyte;
    uint32_t bits;
    unsigned int numbits;
} OldBuf;

static void old_init(OldBuf *s, const uint8_t *data, int len) {
    s->startoffs = 0; s->eof = 1; s->buffer = data;
    s->bufsize = len; s->bufbytes = len; s->currbyte = 0;
    s->bits = 0; s->numbits = 0;
}
static inline int old_left(OldBuf *s) { return s->bufbytes - s->currbyte; }
static inline uint32_t old_peekbyte(OldBuf *s, int o) { return s->buffer[s->currbyte + o]; }
static inline void old_skipbytes(OldBuf *s, int n) { s->currbyte += n; }
static inline void old_checkfillbuf(OldBuf *s) { /* eof=1 → never fills */ }

static void old_fillbits(OldBuf *s) {
    old_checkfillbuf(s);
    int numbytes = (32 - s->numbits) >> 3;
    int left = old_left(s);
    if (numbytes > left) numbytes = left;
    int startoffset = s->numbits >> 3;
    switch (numbytes) {
        case 4: s->bits =
            (old_peekbyte(s,startoffset)<<24)|(old_peekbyte(s,startoffset+1)<<16)|
            (old_peekbyte(s,startoffset+2)<<8)|old_peekbyte(s,startoffset+3); break;
        case 3: s->bits |= ((old_peekbyte(s,startoffset)<<16)|(old_peekbyte(s,startoffset+1)<<8)|
            (old_peekbyte(s,startoffset+2)))<<(8-s->numbits); break;
        case 2: s->bits |= ((old_peekbyte(s,startoffset)<<8)|(old_peekbyte(s,startoffset+1)))<<(16-s->numbits); break;
        case 1: s->bits |= old_peekbyte(s,startoffset)<<(24-s->numbits); break;
    }
    s->numbits += numbytes * 8;
}
static void old_fillbitsLE(OldBuf *s) {
    old_checkfillbuf(s);
    int numbytes = (32 - s->numbits) >> 3;
    int left = old_left(s);
    if (numbytes > left) numbytes = left;
    int startoffset = s->numbits >> 3;
    for (int i = 0; i < numbytes; i++) { s->bits |= old_peekbyte(s,i+startoffset)<<s->numbits; s->numbits += 8; }
}
static inline void old_checkfillbits(OldBuf *s, int n) { if (n > (int)s->numbits) old_fillbits(s); }
static inline void old_checkfillbitsLE(OldBuf *s, int n) { if (n > (int)s->numbits) old_fillbitsLE(s); }
static inline unsigned int old_peekbits(OldBuf *s, int n) { if(!n) return 0; old_checkfillbits(s,n); return s->bits>>(32-n); }
static inline unsigned int old_peekbitsLE(OldBuf *s, int n) { if(!n) return 0; old_checkfillbitsLE(s,n); return s->bits&((1<<n)-1); }
static inline void old_skippeeked(OldBuf *s, int n) {
    int nb = (n-(s->numbits&7)+7)>>3; old_skipbytes(s,nb);
    if (old_left(s)<0) RAISE_EOF();
    s->bits<<=n; s->numbits-=n;
}
static inline void old_skippeekedLE(OldBuf *s, int n) {
    int nb = (n-(s->numbits&7)+7)>>3; old_skipbytes(s,nb);
    if (old_left(s)<0) RAISE_EOF();
    s->bits>>=n; s->numbits-=n;
}
static unsigned int old_nextbitstr(OldBuf *s, int n) { if(!n) return 0; unsigned int b=old_peekbits(s,n); old_skippeeked(s,n); return b; }
static unsigned int old_nextbitstrLE(OldBuf *s, int n) { if(!n) return 0; unsigned int b=old_peekbitsLE(s,n); old_skippeekedLE(s,n); return b; }
static unsigned int old_nextbit(OldBuf *s) { unsigned int b=old_peekbits(s,1); old_skippeeked(s,1); return b; }
static unsigned int old_nextlong(OldBuf *s, int n) {
    if(n<=25) return old_nextbitstr(s,n);
    int rest=n-25; unsigned int b=old_nextbitstr(s,25)<<rest; return b|old_nextbitstr(s,rest);
}
static unsigned int old_nextlongLE(OldBuf *s, int n) {
    if(n<=25) return old_nextbitstrLE(s,n);
    int rest=n-25; unsigned int b=old_nextbitstrLE(s,25); return b|(old_nextbitstrLE(s,rest)<<25);
}
static int64_t old_bufoffset(OldBuf *s) { return s->currbyte - s->startoffs; }
static int64_t old_bitoffset(OldBuf *s) { return old_bufoffset(s)*8 - (s->numbits&7); }
static int old_onboundary(OldBuf *s) { return (s->numbits&7)==0; }
static void old_skiptobyte(OldBuf *s) { s->bits=0; s->numbits=0; }
static void old_skipto16(OldBuf *s) { old_skiptobyte(s); if(old_bufoffset(s)&1) old_skipbytes(s,1); }
static void old_skipbits(OldBuf *s, int n) {
    if(n<=(int)s->numbits) old_skippeeked(s,n);
    else { int sk=n-(s->numbits&7); old_skiptobyte(s); old_skipbytes(s,sk>>3); if(sk&7) old_nextbitstr(s,sk&7); }
}
static void old_skipbitsLE(OldBuf *s, int n) {
    if(n<=(int)s->numbits) old_skippeekedLE(s,n);
    else { int sk=n-(s->numbits&7); old_skiptobyte(s); old_skipbytes(s,sk>>3); if(sk&7) old_nextbitstrLE(s,sk&7); }
}
static uint32_t old_peekbyte_pub(OldBuf *s) { old_checkfillbuf(s); if(old_left(s)<=0) RAISE_EOF(); return old_peekbyte(s,0); }
static uint32_t old_nextbyte(OldBuf *s) { uint32_t b=old_peekbyte_pub(s); old_skipbytes(s,1); return b; }

// ================= NEW(64bit)=================
typedef struct {
    int64_t startoffs;
    int eof;
    const uint8_t *buffer;
    unsigned int bufsize, bufbytes, currbyte;
    uint64_t bits;
    unsigned int numbits;
} NewBuf;

static void new_init(NewBuf *s, const uint8_t *data, int len) {
    s->startoffs = 0; s->eof = 1; s->buffer = data;
    s->bufsize = len; s->bufbytes = len; s->currbyte = 0;
    s->bits = 0; s->numbits = 0;
}
static inline int new_left(NewBuf *s) { return s->bufbytes - s->currbyte; }
static inline uint64_t new_peekbyte(NewBuf *s, int o) { return s->buffer[s->currbyte + o]; }
static inline void new_skipbytes(NewBuf *s, int n) { s->currbyte += n; }
static inline void new_checkfillbuf(NewBuf *s) { }

// 以下のビット操作は CSInputBuffer.[hm] の本番コードを、self→s と helper 名だけ
// 機械的に置換した写し。バッファ補充と EOF 例外だけがハーネスのスタブである。
static void new_fillbits(NewBuf *s)
{
    new_checkfillbuf(s);

    int numbytes=(64-s->numbits)>>3;
    int left=new_left(s);
    int startoffset=s->numbits>>3;
    int available=left-startoffset;
    if(available<0) available=0;
    if(numbytes>available) numbytes=available;

    if(numbytes==8&&s->numbits==0)
    {
        uint64_t value;
        memcpy(&value,s->buffer+s->currbyte,8);
        s->bits=__builtin_bswap64(value);
    }
    else if(numbytes>0)
    {
        uint64_t accumulated=0;
        for(int i=0;i<numbytes;i++)
        {
            accumulated=(accumulated<<8)|new_peekbyte(s,startoffset+i);
        }
        s->bits|=accumulated<<(64-s->numbits-numbytes*8);
    }

    s->numbits+=numbytes*8;
}

static void new_fillbitsLE(NewBuf *s)
{
    new_checkfillbuf(s);

    int numbytes=(64-s->numbits)>>3;
    int left=new_left(s);
    int startoffset=s->numbits>>3;
    int available=left-startoffset;
    if(available<0) available=0;
    if(numbytes>available) numbytes=available;

    for(int i=0;i<numbytes;i++)
    {
        s->bits|=(uint64_t)new_peekbyte(s,i+startoffset)<<s->numbits;
        s->numbits+=8;
    }
}
static inline void new_checkfillbits(NewBuf *s, int n) { if (n > (int)s->numbits) new_fillbits(s); }
static inline void new_checkfillbitsLE(NewBuf *s, int n) { if (n > (int)s->numbits) new_fillbitsLE(s); }
static inline unsigned int new_peekbits(NewBuf *s,int n)
{
    if(n==0) return 0;
    new_checkfillbits(s,n);
    return (unsigned int)(s->bits>>(64-n));
}

static inline unsigned int new_peekbitsLE(NewBuf *s,int n)
{
    if(n==0) return 0;
    new_checkfillbitsLE(s,n);
    return (unsigned int)(s->bits&(((uint64_t)1<<n)-1));
}

static inline void new_skippeeked(NewBuf *s,int n)
{
    int numbytes=(n-(s->numbits&7)+7)>>3;
    new_skipbytes(s,numbytes);

    if(new_left(s)<0) RAISE_EOF();

    if(n>=64) s->bits=0;
    else s->bits<<=n;
    s->numbits-=n;
}

static inline void new_skippeekedLE(NewBuf *s,int n)
{
    int numbytes=(n-(s->numbits&7)+7)>>3;
    new_skipbytes(s,numbytes);

    if(new_left(s)<0) RAISE_EOF();

    if(n>=64) s->bits=0;
    else s->bits>>=n;
    s->numbits-=n;
}
static unsigned int new_nextbitstr(NewBuf *s, int n) { if(!n) return 0; unsigned int b=new_peekbits(s,n); new_skippeeked(s,n); return b; }
static unsigned int new_nextbitstrLE(NewBuf *s, int n) { if(!n) return 0; unsigned int b=new_peekbitsLE(s,n); new_skippeekedLE(s,n); return b; }
static unsigned int new_nextbit(NewBuf *s) { unsigned int b=new_peekbits(s,1); new_skippeeked(s,1); return b; }
static unsigned int new_nextlong(NewBuf *s, int n) {
    if(n<=25) return new_nextbitstr(s,n);
    int rest=n-25; unsigned int b=new_nextbitstr(s,25)<<rest; return b|new_nextbitstr(s,rest);
}
static unsigned int new_nextlongLE(NewBuf *s, int n) {
    if(n<=25) return new_nextbitstrLE(s,n);
    int rest=n-25; unsigned int b=new_nextbitstrLE(s,25); return b|(new_nextbitstrLE(s,rest)<<25);
}
static int64_t new_bufoffset(NewBuf *s) { return s->currbyte - s->startoffs; }
static int64_t new_bitoffset(NewBuf *s) { return new_bufoffset(s)*8 - (s->numbits&7); }
static int new_onboundary(NewBuf *s) { return (s->numbits&7)==0; }
static void new_skiptobyte(NewBuf *s) { s->bits=0; s->numbits=0; }
static void new_skipto16(NewBuf *s) { new_skiptobyte(s); if(new_bufoffset(s)&1) new_skipbytes(s,1); }
static void new_skipbits(NewBuf *s, int n) {
    if(n<=(int)s->numbits) new_skippeeked(s,n);
    else { int sk=n-(s->numbits&7); new_skiptobyte(s); new_skipbytes(s,sk>>3); if(sk&7) new_nextbitstr(s,sk&7); }
}
static void new_skipbitsLE(NewBuf *s, int n) {
    if(n<=(int)s->numbits) new_skippeekedLE(s,n);
    else { int sk=n-(s->numbits&7); new_skiptobyte(s); new_skipbytes(s,sk>>3); if(sk&7) new_nextbitstrLE(s,sk&7); }
}
static uint32_t new_peekbyte_pub(NewBuf *s) { new_checkfillbuf(s); if(new_left(s)<=0) RAISE_EOF(); return new_peekbyte(s,0); }
static uint32_t new_nextbyte(NewBuf *s) { uint32_t b=new_peekbyte_pub(s); new_skipbytes(s,1); return b; }

// ================= 差分ドライバ =================
static uint64_t rng;
static uint32_t rnd(void) { rng = rng*6364136223846793005ULL + 1442695040888963407ULL; return rng>>33; }

typedef struct { int kind, nb; } Op;

// 1 つの op を実行し、返り値(あれば has_ret=1)を out に。EOF は longjmp で脱出。
#define GEN_EXEC(PREFIX, T) \
static uint64_t PREFIX##_exec(T *s, Op op, int LE, int *has_ret) { \
    *has_ret = 1; \
    switch (op.kind) { \
        case 0: return PREFIX##_nextbit(s); \
        case 1: return LE?PREFIX##_nextbitstrLE(s,op.nb):PREFIX##_nextbitstr(s,op.nb); \
        case 2: return LE?PREFIX##_nextlongLE(s,op.nb):PREFIX##_nextlong(s,op.nb); \
        case 3: { unsigned int v=LE?PREFIX##_peekbitsLE(s,op.nb):PREFIX##_peekbits(s,op.nb); \
                  if(op.nb){ if(LE) PREFIX##_skippeekedLE(s,op.nb); else PREFIX##_skippeeked(s,op.nb);} return v; } \
        case 4: if(LE) PREFIX##_skipbitsLE(s,op.nb); else PREFIX##_skipbits(s,op.nb); *has_ret=0; return 0; \
        case 5: PREFIX##_skiptobyte(s); *has_ret=0; return 0; \
        case 6: PREFIX##_skipto16(s); *has_ret=0; return 0; \
        case 7: PREFIX##_skiptobyte(s); return PREFIX##_nextbyte(s); /* 実使用: byte 読みは必ず境界で */ \
        case 8: return PREFIX##_onboundary(s); \
    } \
    *has_ret=0; return 0; \
}
GEN_EXEC(old, OldBuf)
GEN_EXEC(new, NewBuf)

static long total_ops = 0, total_seeds = 0;

static int run_seed(uint64_t seed, int nops) {
    rng = seed;
    int len = 64 + rnd()%512;
    uint8_t *data = malloc(len);
    for (int i=0;i<len;i++) data[i] = rnd();
    int LE = seed & 1;
    OldBuf o; NewBuf n; old_init(&o,data,len); new_init(&n,data,len);

    for (int step=0; step<nops; step++) {
        int old_remaining = len - (int)o.currbyte;
        int new_remaining = len - (int)n.currbyte;
        if (old_remaining < 16 || new_remaining < 16) {
            if (!(old_remaining < 16 && new_remaining < 16)) {
                printf("DIVERGE seed=%llu step=%d: end guard old=%d new=%d\n",
                       (unsigned long long)seed, step, old_remaining, new_remaining);
                free(data); return 1;
            }
            free(data); return 0;
        }
        Op op;
        op.kind = rnd()%9;
        if (op.kind==0 && LE) op.kind=1;  // NextBit は BE のみ(LE は NextBitLE 相当を case1 で代替)
        switch (op.kind) {
            case 1: op.nb = 1+rnd()%25; break;
            case 2: op.nb = 26+rnd()%7; break;
            case 3: op.nb = rnd()%25; break;
            case 4: op.nb = rnd()%40; break;
            default: op.nb = 0;
        }
        // OLD 実行
        int o_ret, o_eof=0; uint64_t o_val=0;
        if (setjmp(eofenv)==0) o_val = old_exec(&o, op, LE, &o_ret); else o_eof=1;
        // NEW 実行
        int n_ret, n_eof=0; uint64_t n_val=0;
        if (setjmp(eofenv)==0) n_val = new_exec(&n, op, LE, &n_ret); else n_eof=1;

        if(getenv("TRACE")&&step>=30&&step<=38) fprintf(stderr,"step=%d kind=%d nb=%d LE=%d | OLD cb=%u nb=%u bits=%08x | NEW cb=%u nb=%u bits=%016llx\n",
            step,op.kind,op.nb,LE,o.currbyte,o.numbits,o.bits,n.currbyte,n.numbits,(unsigned long long)n.bits);
        total_ops++;
        // EOF タイミング一致
        if (o_eof != n_eof) {
            printf("DIVERGE seed=%llu step=%d kind=%d nb=%d: EOF old=%d new=%d\n",
                   (unsigned long long)seed, step, op.kind, op.nb, o_eof, n_eof);
            free(data); return 1;
        }
        if (o_eof) { free(data); return 0; }  // 両方 EOF = 正常終了
        // 返り値一致
        if (o_ret && o_val != n_val) {
            printf("DIVERGE seed=%llu step=%d kind=%d nb=%d LE=%d: val old=%llu new=%llu\n",
                   (unsigned long long)seed, step, op.kind, op.nb, LE,
                   (unsigned long long)o_val, (unsigned long long)n_val);
            free(data); return 1;
        }
        // レザバー内容一致(未消費ビット。peek で露出しない相違を捕捉)
        {
            unsigned int cmpbits = o.numbits < n.numbits ? o.numbits : n.numbits;
            if (cmpbits > 32) cmpbits = 32;
            if (cmpbits > 0) {
                uint64_t ores, nres;
                if (LE) { ores = o.bits & ((cmpbits>=32)?0xffffffffULL:(((uint64_t)1<<cmpbits)-1));
                          nres = n.bits & ((cmpbits>=32)?0xffffffffULL:(((uint64_t)1<<cmpbits)-1)); }
                else    { ores = (uint64_t)o.bits >> (32-cmpbits);
                          nres = n.bits >> (64-cmpbits); }
                if (ores != nres) {
                    printf("RESERVOIR-DIVERGE seed=%llu step=%d kind=%d nb=%d LE=%d: cmpbits=%u old=%llx new=%llx (obits=%08x/%u nbits=%016llx/%u)\n",
                        (unsigned long long)seed,step,op.kind,op.nb,LE,cmpbits,
                        (unsigned long long)ores,(unsigned long long)nres,o.bits,o.numbits,(unsigned long long)n.bits,n.numbits);
                    free(data); return 1;
                }
            }
        }
        // 位置一致(BufferOffset / BitOffset)
        if (old_bufoffset(&o)!=new_bufoffset(&n) || old_bitoffset(&o)!=new_bitoffset(&n)) {
            printf("DIVERGE seed=%llu step=%d kind=%d nb=%d: pos bufoff old=%lld new=%lld bitoff old=%lld new=%lld\n",
                   (unsigned long long)seed, step, op.kind, op.nb,
                   (long long)old_bufoffset(&o),(long long)new_bufoffset(&n),
                   (long long)old_bitoffset(&o),(long long)new_bitoffset(&n));
            free(data); return 1;
        }
    }
    free(data);
    return 0;
}

int main(int argc, char**argv) {
    long nseeds = argc>1 ? atol(argv[1]) : 200000;
    int nops = argc>2 ? atoi(argv[2]) : 400;
    for (long i=0;i<nseeds;i++) {
        total_seeds++;
        if (run_seed(0x9e3779b97f4a7c15ULL ^ (uint64_t)i*2654435761ULL, nops)) {
            printf("FAIL after %ld seeds, %ld ops\n", total_seeds, total_ops);
            return 1;
        }
    }
    printf("OK %ld seeds, %ld ops, no divergence\n", total_seeds, total_ops);
    return 0;
}
