#import "audio/AACEncoder.h"
#import <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>

#define RDP_LOG_COMPONENT "audio"
#include "logging/RDPLog.h"

/* What the input callback says when it has handed over everything there is:
 * the converter then returns with the packets it could finish. */
static const OSStatus kNoMoreInput = 'mrxE';

struct RDPAACEncoder {
    AudioConverterRef converter;
    uint32_t rate, channels;
    uint8_t adtsRateIndex;
    /* PCM not yet given to the converter. */
    int16_t *pending;
    size_t pendingFrames, pendingCap;
    /* What the input callback gives in one go, and whether it has. */
    BOOL handedOver;
    uint8_t *packet;
    UInt32 maxPacket;
    uint8_t *out;
    size_t outLength, outCap;
};

static int adts_rate_index(uint32_t rate) {
    static const uint32_t rates[] = { 96000, 88200, 64000, 48000, 44100, 32000,
                                      24000, 22050, 16000, 12000, 11025, 8000 };
    for (int i = 0; i < 12; i++) if (rates[i] == rate) return i;
    return -1;
}

RDPAACEncoder *rdp_aac_encoder_new(uint32_t sampleRate, uint32_t channels, uint32_t bitRate) {
    int index = adts_rate_index(sampleRate);
    if (index < 0 || channels < 1 || channels > 2) return NULL;
    AudioStreamBasicDescription in = {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 16,
    };
    AudioStreamBasicDescription out = {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatMPEG4AAC,
        .mFormatFlags = kMPEG4Object_AAC_LC,
        .mFramesPerPacket = 1024,
        .mChannelsPerFrame = channels,
    };
    RDPAACEncoder *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    OSStatus st = AudioConverterNew(&in, &out, &e->converter);
    if (st != noErr) {
        rdp_error("AAC encoder unavailable at %u Hz (%d)", sampleRate, (int)st);
        free(e);
        return NULL;
    }
    UInt32 rate = bitRate;
    (void)AudioConverterSetProperty(e->converter, kAudioConverterEncodeBitRate, sizeof rate, &rate);
    UInt32 size = sizeof e->maxPacket;
    if (AudioConverterGetProperty(e->converter, kAudioConverterPropertyMaximumOutputPacketSize,
                                  &size, &e->maxPacket) != noErr || !e->maxPacket)
        e->maxPacket = 6144;
    e->packet = malloc(e->maxPacket);
    e->rate = sampleRate;
    e->channels = channels;
    e->adtsRateIndex = (uint8_t)index;
    if (!e->packet) { rdp_aac_encoder_free(e); return NULL; }
    return e;
}

void rdp_aac_encoder_free(RDPAACEncoder *e) {
    if (!e) return;
    if (e->converter) AudioConverterDispose(e->converter);
    free(e->pending);
    free(e->packet);
    free(e->out);
    free(e);
}

static OSStatus give_input(AudioConverterRef converter, UInt32 *ioPackets, AudioBufferList *data,
                           AudioStreamPacketDescription **descriptions, void *user) {
    (void)converter; (void)descriptions;
    RDPAACEncoder *e = user;
    if (e->handedOver || e->pendingFrames == 0) {
        *ioPackets = 0;
        return kNoMoreInput;
    }
    /* The converter keeps what it is given; all of it goes at once. */
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = e->channels;
    data->mBuffers[0].mData = e->pending;
    data->mBuffers[0].mDataByteSize = (UInt32)(e->pendingFrames * 2 * e->channels);
    *ioPackets = (UInt32)e->pendingFrames;
    e->handedOver = YES;
    return noErr;
}

static BOOL append(RDPAACEncoder *e, const void *bytes, size_t length) {
    if (e->outLength + length > e->outCap) {
        size_t cap = (e->outLength + length) * 2;
        uint8_t *grown = realloc(e->out, cap);
        if (!grown) return NO;
        e->out = grown;
        e->outCap = cap;
    }
    memcpy(e->out + e->outLength, bytes, length);
    e->outLength += length;
    return YES;
}

const uint8_t *rdp_aac_encoder_encode(RDPAACEncoder *e, const int16_t *pcm, uint32_t frames,
                                      size_t *length) {
    *length = 0;
    if (!e) return NULL;
    e->outLength = 0;
    if (e->pendingFrames + frames > e->pendingCap) {
        size_t cap = (e->pendingFrames + frames) * 2;
        int16_t *grown = realloc(e->pending, cap * 2 * e->channels);
        if (!grown) return NULL;
        e->pending = grown;
        e->pendingCap = cap;
    }
    memcpy(e->pending + e->pendingFrames * e->channels, pcm, (size_t)frames * 2 * e->channels);
    e->pendingFrames += frames;
    e->handedOver = NO;
    for (;;) {
        AudioBufferList list = { .mNumberBuffers = 1 };
        list.mBuffers[0].mNumberChannels = e->channels;
        list.mBuffers[0].mData = e->packet;
        list.mBuffers[0].mDataByteSize = e->maxPacket;
        UInt32 packets = 1;
        AudioStreamPacketDescription description = {0};
        OSStatus st = AudioConverterFillComplexBuffer(e->converter, give_input, e, &packets, &list,
                                                      &description);
        if (packets == 0 || list.mBuffers[0].mDataByteSize == 0) {
            if (st != noErr && st != kNoMoreInput) rdp_error("AAC encode failed (%d)", (int)st);
            break;
        }
        size_t payload = list.mBuffers[0].mDataByteSize;
        size_t frameLength = 7 + payload;
        uint8_t adts[7] = {
            0xFF, 0xF1,   /* sync, MPEG-4, no CRC */
            (uint8_t)((1u << 6) | (e->adtsRateIndex << 2) | (e->channels >> 2)),   /* AAC LC */
            (uint8_t)(((e->channels & 3u) << 6) | (frameLength >> 11)),
            (uint8_t)((frameLength >> 3) & 0xFF),
            (uint8_t)(((frameLength & 7u) << 5) | 0x1F),
            0xFC,
        };
        if (!append(e, adts, sizeof adts) || !append(e, e->packet, payload)) break;
    }
    /* Everything was handed over once the callback ran; keep nothing twice. */
    if (e->handedOver) e->pendingFrames = 0;
    *length = e->outLength;
    return e->out;
}
