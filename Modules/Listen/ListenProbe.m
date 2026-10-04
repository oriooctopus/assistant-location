#import "ListenProbe.h"

#import <AVFoundation/AVFoundation.h>

#import "ListenPlayer.h"

#define PROBE(fmt, ...) NSLog(@"ListenProbe: " fmt, ##__VA_ARGS__)

// Strong references so the probes outlive the method that starts them.
static AVQueuePlayer *sEndTimePlayer;
static ListenPlayer *sLoopPlayer;

@implementation ListenProbe

+ (void)runIfRequestedWithWebView:(WKWebView *)webView {
    if (NSProcessInfo.processInfo.environment[@"UITEST_LISTEN_PROBE"].length == 0) return;
    PROBE(@"start; webView=%@ userContentController=%@ pageURL=%@",
          NSStringFromClass([webView class]), NSStringFromClass([webView.configuration.userContentController class]), webView.URL);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self probeBridgeRoundTrip:webView];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self probeForwardPlaybackEndTime];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self probeStepLoop];
    });
}

#pragma mark - Local audio fixtures

/// Writes `seconds` of 440 Hz sine as a 16-bit mono WAV and returns its URL.
+ (NSURL *)writeWavNamed:(NSString *)name seconds:(double)seconds {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[name stringByAppendingString:@".wav"]];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:1 interleaved:NO];
    AVAudioFrameCount frames = (AVAudioFrameCount)(seconds * 44100);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    buffer.frameLength = frames;
    int16_t *samples = buffer.int16ChannelData[0];
    for (AVAudioFrameCount i = 0; i < frames; i++) samples[i] = (int16_t)(3000 * sin(2 * M_PI * 440 * i / 44100.0));
    NSError *error = nil;
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:format.settings
                                                   commonFormat:AVAudioPCMFormatInt16 interleaved:NO error:&error];
        if (!file || ![file writeFromBuffer:buffer error:&error]) {
            PROBE(@"could not write %@: %@", name, error);
            return nil;
        }
    }
    PROBE(@"wrote %@ (%.1fs) at %@", name, seconds, url.path);
    return url;
}

#pragma mark - 2: bridge round trip

+ (void)probeBridgeRoundTrip:(WKWebView *)webView {
    // 8315 is unreachable in CI (native error page); load a stand-in page so
    // there is a real document to post from.
    [webView loadHTMLString:@"<html><body>probe</body></html>" baseURL:[NSURL URLWithString:@"http://probe.invalid/"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self runBridgeScript:webView];
    });
}

+ (void)runBridgeScript:(WKWebView *)webView {
    NSString *install =
        @"window.__probeLog = [];"
         "window.__listenReply = function (id, r, e) { window.__probeLog.push(['reply', id, r, e]); };"
         "window.__listenEvent = function (n, p) { window.__probeLog.push(['event', n, p]); };"
         "var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.listen;"
         "if (h) { h.postMessage({id: 7, method: 'getState', params: {}}); h.postMessage({id: 8, method: 'play', params: {}}); }"
         "String(!!h) + ' ' + location.href";
    [webView evaluateJavaScript:install completionHandler:^(id result, NSError *error) {
        PROBE(@"page install: handler present + href = %@ (error=%@)", result, error);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [webView evaluateJavaScript:@"JSON.stringify(window.__probeLog)" completionHandler:^(id result, NSError *error) {
            PROBE(@"page received (expect reply 7 = state, reply 8 = error 'no item loaded'): %@ (error=%@)", result, error);
        }];
    });
}

#pragma mark - 3: forwardPlaybackEndTime

+ (void)probeForwardPlaybackEndTime {
    NSURL *url = [self writeWavNamed:@"probe-6s" seconds:6];
    if (!url) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    BOOL ok = [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeSpokenAudio options:0 error:&error] &&
              [session setActive:YES error:&error];
    PROBE(@"playback session activate ok=%d error=%@", ok, error);

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(2.0, 1000);
    sEndTimePlayer = [AVQueuePlayer queuePlayerWithItems:@[item]];
    sEndTimePlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    __block CFAbsoluteTime playedAt = 0;
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        PROBE(@"forwardEnd: DidPlayToEnd after %.2fs of wall time, currentTime=%.2f (seek 1.0, end 2.0: expect ~1.0s / ~2.0)",
              CFAbsoluteTimeGetCurrent() - playedAt, CMTimeGetSeconds(sEndTimePlayer.currentTime));
    }];
    __block int polls = 0;
    __block BOOL seeking = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        polls++;
        if (item.status == AVPlayerItemStatusFailed) {
            PROBE(@"forwardEnd: item failed: %@", item.error);
            [timer invalidate];
        } else if (item.status == AVPlayerItemStatusReadyToPlay && !seeking) {
            seeking = YES;
            PROBE(@"forwardEnd: ready; duration=%.2f; seeking to 1.0", CMTimeGetSeconds(item.duration));
            [item seekToTime:CMTimeMakeWithSeconds(1.0, 1000) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
           completionHandler:^(BOOL finished) {
                PROBE(@"forwardEnd: seek finished=%d currentTime=%.2f; play", finished, CMTimeGetSeconds(sEndTimePlayer.currentTime));
                playedAt = CFAbsoluteTimeGetCurrent();
                [sEndTimePlayer play];
            }];
        }
        if (polls > 24) {
            PROBE(@"forwardEnd: 6s poll over; status=%ld rate=%.2f currentTime=%.2f timeControl=%ld",
                  (long)item.status, sEndTimePlayer.rate, CMTimeGetSeconds(sEndTimePlayer.currentTime), (long)sEndTimePlayer.timeControlStatus);
            [timer invalidate];
        }
    }];
}

#pragma mark - 4: ListenPlayer step loop

+ (void)probeStepLoop {
    NSURL *full = [self writeWavNamed:@"probe-full" seconds:6];
    NSURL *shortClip = [self writeWavNamed:@"probe-short" seconds:0.5];
    if (!full || !shortClip) return;
    NSDictionary *(^section)(double, double, BOOL) = ^NSDictionary *(double start, double end, BOOL vocab) {
        return @{
            @"start": @(start), @"end": @(end),
            @"audio": @{
                @"original": full.absoluteString, @"clear": shortClip.absoluteString,
                @"translation": shortClip.absoluteString,
                @"vocab": vocab ? (id)shortClip.absoluteString : (id)[NSNull null],
            },
        };
    };
    NSDictionary *settings = @{
        @"steps": @[@"vocab", @"clear", @"translation", @"original"],
        @"autoAdvance": @YES, @"rate": @1.25, @"repeatOriginal": @2, @"pocketDoublePress": @"voice", @"pocketReplaySlowdown": @20,
    };
    ListenPlayer *player = [[ListenPlayer alloc] init];
    sLoopPlayer = player;
    __block CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block NSString *last = @"";
    player.stateChanged = ^{
        NSDictionary *s = [player stateDictionary];
        NSString *line = [NSString stringWithFormat:@"idx=%@ step=%@ stepIndex=%@/%@ playing=%@ dur=%.2f err=%@",
                          s[@"idx"], s[@"step"], s[@"stepIndex"], s[@"stepCount"], s[@"playing"], [s[@"duration"] doubleValue], s[@"error"]];
        if ([line isEqualToString:last]) return;
        last = line;
        PROBE(@"loop t=%.2f %@", CFAbsoluteTimeGetCurrent() - t0, line);
    };
    player.errorReported = ^(NSString *message) { PROBE(@"loop ERROR %@", message); };

    NSString *error = [player loadItemId:@"probe" title:@"Probe" sections:@[section(1.0, 1.8, YES), section(3.0, 3.6, NO)]
                                settings:settings startIdx:0];
    PROBE(@"loop load error=%@", error);
    PROBE(@"loop expect: S0 vocab .5, clear .5, english .5, original .64 x2 (0.4 gaps), S1 (no vocab) clear, english, original x2, then playing=NO step=null");
    t0 = CFAbsoluteTimeGetCurrent();
    PROBE(@"loop play error=%@", [player play]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PROBE(@"loop final: %@", [player stateDictionary]);
        PROBE(@"loop replay clear error=%@", [player replay:@"clear"]);
    });
}

@end
