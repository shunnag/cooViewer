#import <Foundation/Foundation.h>
#import "XADString.h"
int main(){ @autoreleasepool {
    int fail=0;
    // escapedASCIIStringForBytes: ランダムなバイト列で旧実装と照合
    for(int trial=0; trial<5000; trial++){
        int len=trial%250+1; uint8_t buf[256];
        srandom(trial); for(int i=0;i<len;i++) buf[i]=random()&0xff;
        NSMutableString *ref=[NSMutableString stringWithCapacity:len];
        for(int i=0;i<len;i++){ if(buf[i]<0x80)[ref appendFormat:@"%c",buf[i]]; else [ref appendFormat:@"%%%02x",buf[i]]; }
        NSString *got=[XADString escapedASCIIStringForBytes:buf length:len];
        if(![got isEqualToString:ref]){ printf("STR MISMATCH trial=%d\n",trial); fail++; if(fail>3)break; }
    }
    // escapedASCIIDataForString: ASCII/CJK/サロゲート/U+FFFF を含む文字列で照合
    NSMutableArray *strs=[NSMutableArray array];
    [strs addObject:@"hello world"];
    [strs addObject:[NSString stringWithFormat:@"%C.png", (unichar)0x56F3]];       // 図
    [strs addObject:@"path/to/file"];
    [strs addObject:[NSString stringWithFormat:@"%C%C%C", (unichar)0x76EE,(unichar)0x6B21,(unichar)0x30C6]]; // 目次テ
    // サロゲートペア(絵文字 U+1F389)を UTF-16 単位で構築
    [strs addObject:[NSString stringWithFormat:@"%C%C", (unichar)0xD83C,(unichar)0xDF89]];
    [strs addObject:[NSString stringWithFormat:@"%C", (unichar)0xFFFF]];
    for(NSString *s in strs){
        NSMutableData *ref=[NSMutableData data];
        for(int i=0;i<[s length];i++){ char b[8]; unichar c=[s characterAtIndex:i];
            if(c<0x80){b[0]=c;[ref appendBytes:b length:1];} else {sprintf(b,"%%u%04x",c&0xffff);[ref appendBytes:b length:6];} }
        NSData *got=[XADString escapedASCIIDataForString:s];
        if(![got isEqualToData:ref]){ printf("DATA MISMATCH len=%lu\n",(unsigned long)[s length]); fail++; }
    }
    printf(fail?"FAIL %d\n":"OK all identical\n",fail);
    return fail?1:0;
} }
