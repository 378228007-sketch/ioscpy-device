#import "Encoder.h"

#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <arpa/inet.h>
#import <dlfcn.h>

BOOL IOSPYH264Available(void) {
    // VideoToolbox is present on every device we target; the real gate is whether
    // a session can actually be created, which encodeSurface: reports per-frame
    // (returning nil so the caller falls back to MJPEG). Keep this as the single
    // place to add a stricter probe if a future layout ever needs one.
    return YES;
}


// Newer VideoToolbox keys (iOS 16+/macOS 12+) are not exported on iOS 14, and a
// dylib that hard-references them fails to load there at all. Resolve them at
// runtime instead: a build that links must keep loading on older systems.
static CFStringRef IOSPYVTPropKey(const char *symbolName) {
    CFStringRef *slot = (CFStringRef *)dlsym(RTLD_DEFAULT, symbolName);
    return slot ? *slot : NULL;
}

@implementation IOSPYH264Encoder {
    VTCompressionSessionRef _session;
    int _w, _h, _fps;
    int64_t _pts;          // monotonic frame index for presentation timestamps
}

- (void)invalidate {
    if (_session) {
        VTCompressionSessionCompleteFrames(_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _w = _h = _fps = 0;
}

- (void)dealloc {
    [self invalidate];
}

// Best-effort property set. An OS that doesn't know a key just keeps its default
// rather than failing the whole session, which keeps us portable across versions.
- (void)setProp:(CFStringRef)key number:(int)value {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
    VTSessionSetProperty(_session, key, n);
    CFRelease(n);
}

- (void)setProp:(CFStringRef)key real:(double)value {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    VTSessionSetProperty(_session, key, n);
    CFRelease(n);
}

- (BOOL)ensureSessionForWidth:(int)width height:(int)height fps:(int)fps {
    if (_session && _w == width && _h == height && _fps == fps) {
        return YES;
    }
    [self invalidate];

    // Ask the encoder to vend BGRA IOSurface-backed buffers so wrapping the
    // capture surface is zero-copy.
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };

    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
                                            kCMVideoCodecType_H264, NULL,
                                            (__bridge CFDictionaryRef)srcAttrs, NULL,
                                            NULL, NULL, &_session);
    if (s != noErr || !_session) {
        NSLog(@"[ioscpyhook] VTCompressionSessionCreate failed (%d)", (int)s);
        _session = NULL;
        return NO;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    // Main profile: CABAC entropy coding, ~10-15% better quality at the same
    // bitrate than Baseline (which is CAVLC-only). Host FFmpeg H.264 decoder
    // does not care about profile, so no client change is needed.
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Main_AutoLevel);

    // Latency knobs: prefer encode speed over compression efficiency, and forbid
    // the encoder from holding frames back for lookahead/reordering. Both are
    // best-effort like the rest (an OS that lacks the key keeps its default).
    CFStringRef prioritizeSpeedKey =
        IOSPYVTPropKey("VTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality");
    if (prioritizeSpeedKey) {
        VTSessionSetProperty(_session, prioritizeSpeedKey, kCFBooleanTrue);
    }
    CFStringRef maxFrameDelayKey =
        IOSPYVTPropKey("VTCompressionPropertyKey_MaxFrameDelayCount");
    if (maxFrameDelayKey) {
        [self setProp:maxFrameDelayKey number:0];
    }

    // Refresh a keyframe at least every few seconds (and bound by frame count) so
    // a host that joins mid-stream recovers quickly.
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameInterval number:fps * 4];
    [self setProp:kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration real:4.0];
    [self setProp:kVTCompressionPropertyKey_ExpectedFrameRate number:fps];

    // Cap bandwidth. Raised with the 1600->1920 longest-side change: 1080p-class
    // screen content needs more headroom to stay clean during motion.
    int avgBitrate = 16 * 1000 * 1000;
    [self setProp:kVTCompressionPropertyKey_AverageBitRate number:avgBitrate];
    int byteCap = (int)((double)avgBitrate / 8.0 * 1.5);
    NSArray *limits = @[ @(byteCap), @(1.0) ]; // bytes per 1-second window
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_DataRateLimits,
                         (__bridge CFArrayRef)limits);

    VTCompressionSessionPrepareToEncodeFrames(_session);

    _w = width;
    _h = height;
    _fps = fps;
    _pts = 0;
    NSLog(@"[ioscpyhook] H.264 session ready %dx%d @%dfps", width, height, fps);
    return YES;
}

// Append one NAL in AVCC framing (4-byte big-endian length prefix) to dst.
static void appendAVCC(NSMutableData *dst, const uint8_t *nal, size_t len) {
    uint32_t be = htonl((uint32_t)len);
    [dst appendBytes:&be length:4];
    [dst appendBytes:nal length:len];
}

- (void)encodeSurface:(IOSurfaceRef)surface
                 width:(int)width
                height:(int)height
                   fps:(int)fps
         forceKeyframe:(BOOL)forceKeyframe
            completion:(void (^)(NSData *avcc, BOOL isKey, BOOL failed))completion {
    if (!completion) {
        return;
    }
    if (!surface || width < 2 || height < 2) {
        completion(nil, NO, YES);
        return;
    }
    if (![self ensureSessionForWidth:width height:height fps:fps]) {
        completion(nil, NO, YES);
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    if (cr != kCVReturnSuccess || !pixelBuffer) {
        completion(nil, NO, YES);
        return;
    }

    CMTime pts = CMTimeMake(_pts++, fps);
    NSDictionary *frameProps =
        forceKeyframe ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;

    __block NSData *result = nil;
    __block BOOL isKey = NO;

    OSStatus es = VTCompressionSessionEncodeFrameWithOutputHandler(
        _session, pixelBuffer, pts, kCMTimeInvalid, (__bridge CFDictionaryRef)frameProps, NULL,
        ^(OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sample) {
            if (status != noErr) {
                completion(nil, NO, YES);
                return;
            }
            if (!sample || (infoFlags & kVTEncodeInfo_FrameDropped)) {
                completion(nil, NO, NO); // dropped this tick, not an error
                return;
            }

            // A sample is a keyframe unless it's explicitly marked not-sync.
            BOOL key = YES;
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFDictionaryRef d =
                    (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFBooleanRef notSync = NULL;
                if (CFDictionaryGetValueIfPresent(d, kCMSampleAttachmentKey_NotSync,
                                                  (const void **)&notSync) &&
                    notSync && CFBooleanGetValue(notSync)) {
                    key = NO;
                }
            }
            isKey = key;

            NSMutableData *out = [NSMutableData data];

            // On a keyframe, lead with the parameter sets so the stream is
            // self-describing for a host that just connected. If we can't pull all
            // of them, drop this frame (don't mark it a keyframe) so the next one
            // retries rather than shipping a config the host can't decode from.
            if (key) {
                size_t count = 0, appended = 0;
                int nalHeaderLen = 0;
                CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
                if (fmt &&
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, 0, NULL, NULL, &count, &nalHeaderLen) == noErr) {
                    for (size_t i = 0; i < count; i++) {
                        const uint8_t *ps = NULL;
                        size_t psLen = 0;
                        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                                fmt, i, &ps, &psLen, NULL, NULL) == noErr && ps) {
                            appendAVCC(out, ps, psLen);
                            appended++;
                        }
                    }
                }
                if (count == 0 || appended != count) {
                    NSLog(@"[ioscpyhook] incomplete H.264 parameter sets; retrying keyframe");
                    isKey = NO;
                    completion(nil, NO, NO); // dropped tick; the next frame retries
                    return;
                }
            }

            // The sample data is already AVCC (length-prefixed) coming out of
            // VideoToolbox, so copy it across verbatim.
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sample);
            if (bb) {
                size_t total = CMBlockBufferGetDataLength(bb);
                NSMutableData *nalData = [NSMutableData dataWithLength:total];
                if (CMBlockBufferCopyDataBytes(bb, 0, total, nalData.mutableBytes) == noErr) {
                    [out appendData:nalData];
                }
            }
            result = out;
            completion(result, isKey, NO);
        });

    if (es != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        NSLog(@"[ioscpyhook] H.264 encode enqueue failed (%d)", (int)es);
        completion(nil, NO, YES);
        return;
    }

    // No flush here. The encoded frame leaves through the output handler above, so
    // the capture tick is free the moment the frame is queued instead of waiting
    // for the encoder to finish it. The old VTCompressionSessionCompleteFrames
    // call blocked that tick every frame, serialising capture and encode - that
    // wait was the bulk of the added latency. MaxFrameDelayCount=1 bounds the
    // encoder's queue to one frame.
    CVPixelBufferRelease(pixelBuffer);
}

@end
