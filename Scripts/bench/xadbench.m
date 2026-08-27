// XADMaster ベンチマークハーネス。
// 使い方: xadbench <open|extract|random|data-open> <archive> <reps> [count]
//   open     — 開く+全エントリの名前/ディレクトリ判定/サイズ取得(cooViewer の列挙相当)を reps 回
//   extract  — 1 回開き、全エントリを書庫順に contentsOfEntry: で reps 周(SHA-256 で正しさ検証)
//   random   — 1 回開き、決定論的な擬似乱数順で count エントリを展開 × reps
//   data-open — mmap した NSData から開く(open と同じ計測。initWithData 経路)
// 出力: JSON 1 行(rep ごとの ms、総バイト、正しさダイジェスト)
#import <Foundation/Foundation.h>
#import <XADMaster/XADArchive.h>
#import <CommonCrypto/CommonDigest.h>
#include <time.h>

static double now_ms(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

// 決定論的 LCG(random モードの順序を全バリアントで一致させる)
static uint64_t lcg_state;
static uint64_t lcg_next(void) {
    lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return lcg_state >> 33;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <mode> <archive> <reps> [count]\n", argv[0]); return 2; }
    NSString *mode = @(argv[1]);
    NSString *path = @(argv[2]);
    int reps = atoi(argv[3]);
    int count = argc > 4 ? atoi(argv[4]) : 0;

    NSMutableArray *repMs = [NSMutableArray array];
    unsigned long long totalBytes = 0;
    long long entryCount = -1;
    // 正しさ検証: エントリごとの SHA-256 を連結した列の SHA-256(順序も検証される)
    CC_SHA256_CTX overall;
    CC_SHA256_Init(&overall);
    BOOL hashed = NO;

    if ([mode isEqualToString:@"open"] || [mode isEqualToString:@"data-open"]) {
        BOOL fromData = [mode isEqualToString:@"data-open"];
        for (int r = 0; r < reps; r++) {
            @autoreleasepool {
                double t0 = now_ms();
                XADArchive *a;
                if (fromData) {
                    NSData *d = [NSData dataWithContentsOfFile:path
                        options:NSDataReadingMappedAlways error:NULL];
                    if (!d) { fprintf(stderr, "map failed\n"); return 1; }
                    a = [[XADArchive alloc] initWithData:d error:NULL];
                } else {
                    a = [[XADArchive alloc] initWithFile:path error:NULL];
                }
                if (!a) { fprintf(stderr, "open failed\n"); return 1; }
                int n = [a numberOfEntries];
                unsigned long long nameBytes = 0;
                for (int i = 0; i < n; i++) {
                    NSString *name = [a nameOfEntry:i];
                    nameBytes += [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    if ([a entryIsDirectory:i]) continue;
                    totalBytes += (unsigned long long)[a representativeSizeOfEntry:i];
                }
                entryCount = n;
                (void)nameBytes;
                [repMs addObject:@(now_ms() - t0)];
            }
        }
    } else if ([mode isEqualToString:@"extract"] || [mode isEqualToString:@"random"]) {
        XADArchive *a = [[XADArchive alloc] initWithFile:path error:NULL];
        if (!a) { fprintf(stderr, "open failed\n"); return 1; }
        const char *pw = getenv("XADBENCH_PASSWORD");
        if (pw) [a setPassword:@(pw)];
        int n = [a numberOfEntries];
        entryCount = n;
        NSMutableArray *files = [NSMutableArray array];
        for (int i = 0; i < n; i++) {
            if (![a entryIsDirectory:i]) [files addObject:@(i)];
        }
        BOOL isRandom = [mode isEqualToString:@"random"];
        for (int r = 0; r < reps; r++) {
            NSMutableArray *order = files;
            if (isRandom) {
                lcg_state = 42;  // 毎 rep 同じ順序(バリアント間で一致)
                order = [NSMutableArray array];
                for (int i = 0; i < count; i++) {
                    [order addObject:files[lcg_next() % files.count]];
                }
            }
            double t0 = now_ms();
            for (NSNumber *idx in order) {
                @autoreleasepool {
                    NSData *d = [a contentsOfEntry:idx.intValue];
                    if (!d) { fprintf(stderr, "extract failed entry %d\n", idx.intValue); return 1; }
                    totalBytes += d.length;
                    if (r == 0) {  // ダイジェストは初回周のみ(計測 rep 間で同一のはず)
                        unsigned char h[CC_SHA256_DIGEST_LENGTH];
                        CC_SHA256(d.bytes, (CC_LONG)d.length, h);
                        CC_SHA256_Update(&overall, h, sizeof(h));
                        hashed = YES;
                    }
                }
            }
            [repMs addObject:@(now_ms() - t0)];
        }
    } else if ([mode isEqualToString:@"pextract"]) {
        // group-aware 並列展開: solidGroupOfEntry でエントリをグループに束ね、
        // グループ単位でワーカー(独立 XADArchive)へ round-robin 配分する。
        // グループ内はエントリ順に前進ストリーミング(solid の巻き戻しなし)。
        // ダイジェストはエントリ順の per-entry SHA 連結 = extract モードと同一になる
        int workers = count > 0 ? count : 6;
        XADArchive *probe = [[XADArchive alloc] initWithFile:path error:NULL];
        if (!probe) { fprintf(stderr, "open failed\n"); return 1; }
        int n = [probe numberOfEntries];
        entryCount = n;
        NSMutableArray *files = [NSMutableArray array];
        for (int i = 0; i < n; i++) {
            if (![probe entryIsDirectory:i]) [files addObject:@(i)];
        }
        // グループ→エントリ列(出現順)
        NSMutableArray *groupOrder = [NSMutableArray array];
        NSMutableDictionary *groups = [NSMutableDictionary dictionary];
        for (NSNumber *idx in files) {
            NSInteger g = [probe solidGroupOfEntry:idx.intValue];
            NSNumber *key = g >= 0 ? @(g) : @(-1000000 - idx.intValue);  // 独立エントリは単独グループ
            NSMutableArray *members = groups[key];
            if (!members) { members = [NSMutableArray array]; groups[key] = members; [groupOrder addObject:key]; }
            [members addObject:idx];
        }
        NSUInteger fileTotal = files.count;
        unsigned char (*digests)[CC_SHA256_DIGEST_LENGTH] =
            calloc(fileTotal, CC_SHA256_DIGEST_LENGTH);
        // エントリ番号→ダイジェスト格納位置(= extract モードの順序)
        NSMutableDictionary *slotOf = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < fileTotal; i++) slotOf[files[i]] = @(i);

        for (int r = 0; r < reps; r++) {
            __block unsigned long long repBytes = 0;
            double t0 = now_ms();
            dispatch_queue_t sync = dispatch_queue_create("bytes", DISPATCH_QUEUE_SERIAL);
            dispatch_group_t dg = dispatch_group_create();
            dispatch_queue_t pool = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
            for (int w = 0; w < workers; w++) {
                dispatch_group_async(dg, pool, ^{
                    @autoreleasepool {
                        XADArchive *a = [[XADArchive alloc] initWithFile:path error:NULL];
                        if (!a) return;
                        unsigned long long localBytes = 0;
                        for (NSUInteger gi = w; gi < groupOrder.count; gi += workers) {
                            for (NSNumber *idx in groups[groupOrder[gi]]) {
                                @autoreleasepool {
                                    NSData *d = [a contentsOfEntry:idx.intValue];
                                    if (!d) continue;
                                    localBytes += d.length;
                                    if (r == 0) {
                                        NSUInteger slot = [slotOf[idx] unsignedIntegerValue];
                                        CC_SHA256(d.bytes, (CC_LONG)d.length, digests[slot]);
                                    }
                                }
                            }
                        }
                        dispatch_sync(sync, ^{ repBytes += localBytes; });
                    }
                });
            }
            dispatch_group_wait(dg, DISPATCH_TIME_FOREVER);
            [repMs addObject:@(now_ms() - t0)];
            totalBytes += repBytes;
        }
        for (NSUInteger i = 0; i < fileTotal; i++) {
            CC_SHA256_Update(&overall, digests[i], CC_SHA256_DIGEST_LENGTH);
        }
        hashed = fileTotal > 0;
        free(digests);
    } else {
        fprintf(stderr, "unknown mode\n");
        return 2;
    }

    NSMutableString *json = [NSMutableString string];
    [json appendFormat:@"{\"mode\":\"%@\",\"archive\":\"%@\",\"entries\":%lld,\"bytes\":%llu,\"rep_ms\":[",
        mode, [path lastPathComponent], entryCount, totalBytes];
    for (NSUInteger i = 0; i < repMs.count; i++) {
        [json appendFormat:@"%s%.2f", i ? "," : "", [repMs[i] doubleValue]];
    }
    [json appendString:@"]"];
    if (hashed) {
        unsigned char dig[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(dig, &overall);
        [json appendString:@",\"sha256\":\""];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [json appendFormat:@"%02x", dig[i]];
        [json appendString:@"\""];
    }
    [json appendString:@"}"];
    printf("%s\n", json.UTF8String);
    return 0;
}
