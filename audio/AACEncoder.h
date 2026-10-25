#pragma once
/*
 * AAC-LC for the audio channel while the client saves data (mRemote's
 * docs/changes/2026-10-25-data-saver.md): interleaved 16-bit PCM in, ADTS
 * frames out - one per 1024 frames - so each wave stands on its own and the
 * client needs no setup beyond the format's rate and channels.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The audio channel's private format tag for it (macrdpx's AUDIO_AAC). */
#define RDP_WAVE_FORMAT_MRX_AAC 0x4D52

typedef struct RDPAACEncoder RDPAACEncoder;

/* NULL when the system cannot encode at this rate. */
RDPAACEncoder *rdp_aac_encoder_new(uint32_t sampleRate, uint32_t channels, uint32_t bitRate);
void rdp_aac_encoder_free(RDPAACEncoder *encoder);

/* Takes frames of PCM and returns the ADTS frames finished so far (possibly
 * none: the encoder works in blocks of 1024 frames). The bytes stay valid
 * until the next call. */
const uint8_t *rdp_aac_encoder_encode(RDPAACEncoder *encoder, const int16_t *pcm,
                                      uint32_t frames, size_t *length);

#ifdef __cplusplus
}
#endif
