#import <Foundation/Foundation.h>

// Swift の do/catch では捕捉できない書庫エンジンの例外を監査結果へ変換する。
// 返す文字列の所有権は Swift 側へ渡す(開発ガイド §2.1)。
void *CooArchiveAuditCatchException(void (^operation)(void)) {
    @try {
        operation();
        return NULL;
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"%@: %@",
            exception.name, exception.reason ?: @""];
        return (void *)CFBridgingRetain(message);
    }
}
