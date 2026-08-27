#import <Foundation/Foundation.h>
#import "XADString.h"
#include <time.h>
static double ms(){ return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6; }
int main(){ @autoreleasepool {
    // 2000 エントリ相当 × 40 バイト名(全て高位バイト=%xx に倒れる)
    uint8_t buf[40]; for(int i=0;i<40;i++) buf[i]=0x80+(i%128);
    int N=2000, reps=5;
    double best=1e9;
    for(int r=0;r<reps;r++){ double t=ms();
        for(int i=0;i<N;i++){ @autoreleasepool { NSString *s=[XADString escapedASCIIStringForBytes:buf length:40]; (void)s; } }
        double d=ms()-t; if(d<best)best=d; }
    printf("escapedASCIIStringForBytes x%d(40B): %.2f ms\n", N, best);
    return 0;
} }
