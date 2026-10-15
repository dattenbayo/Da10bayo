// Мост к приватному MediaRemote.framework — «Сейчас играет» системы.
// С macOS 15.4 MediaRemote отдаёт данные только процессам Apple, поэтому этот
// dylib загружается в системный /usr/bin/perl (см. Helpers/mediaremote.pl),
// а Da10bayo общается с ним через stdin/stdout:
//   stdout — по строке JSON на каждое изменение;
//   stdin  — команды: play, pause, toggle, next, previous, shuffle, repeat, like, seek <сек>, refresh.
// Так видно любой плеер, который публикует Now Playing: Яндекс Музыку,
// браузеры, Spotify, Музыку, VLC и т. д.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CommonCrypto/CommonDigest.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static GetInfoFn MRGetInfo;
static GetPIDFn MRGetPID;
static GetPlayingFn MRGetPlaying;
static RegisterFn MRRegister;
static SendCommandFn MRSend;
static SetElapsedFn MRSetElapsed;

static dispatch_queue_t gQueue;
static NSString *gLastArtworkHash;
static NSString *gLastLine;

static void emit(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:gLastLine]) return;
    gLastLine = line;
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static NSString *sha1(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

static id value(NSDictionary *info, NSString *key) {
    id v = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
    return v == [NSNull null] ? nil : v;
}

static void refresh(void) {
    MRGetPID(gQueue, ^(int pid) {
        MRGetPlaying(gQueue, ^(Boolean playing) {
            MRGetInfo(gQueue, ^(CFDictionaryRef ref) {
                NSDictionary *info = (__bridge NSDictionary *)ref;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = @(playing ? YES : NO);
                if (pid > 0) {
                    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                    if (app.bundleIdentifier) out[@"bundle"] = app.bundleIdentifier;
                    if (app.localizedName) out[@"appName"] = app.localizedName;
                }
                if (info.count > 0) {
                    NSString *title = value(info, @"Title");
                    if (title) out[@"title"] = title;
                    NSString *artist = value(info, @"Artist");
                    if (artist) out[@"artist"] = artist;
                    NSString *album = value(info, @"Album");
                    if (album) out[@"album"] = album;
                    NSNumber *duration = value(info, @"Duration");
                    if (duration) out[@"duration"] = duration;
                    NSNumber *elapsed = value(info, @"ElapsedTime");
                    if (elapsed) out[@"elapsed"] = elapsed;
                    NSNumber *rate = value(info, @"PlaybackRate");
                    if (rate) out[@"rate"] = rate;
                    NSDate *ts = value(info, @"Timestamp");
                    if ([ts isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(ts.timeIntervalSince1970);
                    NSNumber *shuffle = value(info, @"ShuffleMode");
                    if (shuffle) out[@"shuffle"] = shuffle;
                    NSNumber *liked = value(info, @"IsLiked");
                    if (liked) out[@"liked"] = liked;

                    NSData *art = value(info, @"ArtworkData");
                    if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                        NSString *hash = sha1(art);
                        out[@"artworkHash"] = hash;
                        if (![hash isEqualToString:gLastArtworkHash]) {
                            gLastArtworkHash = hash;
                            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        }
                    } else {
                        gLastArtworkHash = nil;
                    }
                }
                emit(out);
            });
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"play"]) MRSend(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSend(1, NULL);
    else if ([cmd isEqualToString:@"toggle"]) MRSend(2, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSend(4, NULL);
    else if ([cmd isEqualToString:@"previous"]) MRSend(5, NULL);
    else if ([cmd isEqualToString:@"shuffle"]) MRSend(6, NULL);
    else if ([cmd isEqualToString:@"repeat"]) MRSend(7, NULL);
    else if ([cmd isEqualToString:@"like"]) MRSend(21, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) MRSetElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) { gLastLine = nil; gLastArtworkHash = nil; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), gQueue, ^{ refresh(); });
}

// Вызывается из perl через DynaLoader::dl_install_xsub — аргументы perl игнорируем.
__attribute__((visibility("default")))
void d10_stream(void *perl, void *cv) {
    (void)perl; (void)cv;
    @autoreleasepool {
        CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
            CFSTR("/System/Library/PrivateFrameworks/MediaRemote.framework"), kCFURLPOSIXPathStyle, true);
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
        CFRelease(url);
        if (!bundle) { fprintf(stderr, "no MediaRemote\n"); exit(2); }

        MRGetInfo = (GetInfoFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingInfo"));
        MRGetPID = (GetPIDFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationPID"));
        MRGetPlaying = (GetPlayingFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationIsPlaying"));
        MRRegister = (RegisterFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteRegisterForNowPlayingNotifications"));
        MRSend = (SendCommandFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteSendCommand"));
        MRSetElapsed = (SetElapsedFn)CFBundleGetFunctionPointerForName(bundle, CFSTR("MRMediaRemoteSetElapsedTime"));
        if (!MRGetInfo || !MRGetPID || !MRGetPlaying || !MRRegister || !MRSend || !MRSetElapsed) {
            fprintf(stderr, "MediaRemote symbols missing\n"); exit(3);
        }

        gQueue = dispatch_queue_create("da10bayo.mediaremote", DISPATCH_QUEUE_SERIAL);
        MRRegister(gQueue);

        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                          usingBlock:^(NSNotification *n) { refresh(); }];
        }

        // Команды из stdin; EOF — родитель завершился, выходим.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char buf[512];
            while (fgets(buf, sizeof buf, stdin)) {
                NSString *line = [[NSString stringWithUTF8String:buf]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length) dispatch_async(gQueue, ^{ handleCommand(line); });
            }
            exit(0);
        });

        // Страховочный опрос: часть плееров не шлёт уведомления при перемотке.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ refresh(); });
        dispatch_resume(timer);

        CFRunLoopRun();
    }
}
