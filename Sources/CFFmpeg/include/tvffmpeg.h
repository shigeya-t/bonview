#ifndef TVFFMPEG_H
#define TVFFMPEG_H

#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

/// MPEG-2 TS stream_type values handled by the decoder.
enum {
    TV_STREAM_MPEG2_VIDEO = 0x02,
    TV_STREAM_AAC_ADTS    = 0x0F,
    TV_STREAM_AAC_LATM    = 0x11,
    TV_STREAM_H264        = 0x1B,
    TV_STREAM_HEVC        = 0x24,
};

#define TV_NOPTS INT64_MIN

/// Called for each decoded picture. `pixelBuffer` is +0 (retain it if you keep it).
/// `pts` is in 90 kHz units (TV_NOPTS if unknown).
typedef void (*tv_video_callback)(void *ctx, CVPixelBufferRef pixelBuffer, int64_t pts,
                                  int sarNum, int sarDen);

/// Called with interleaved float32 PCM. `pts` in 90 kHz units.
typedef void (*tv_audio_callback)(void *ctx, const float *samples, int frames, int channels,
                                  int sampleRate, int64_t pts);

typedef struct TVDecoder TVDecoder;

/// Create a decoder for the given TS stream_type. Returns NULL if unsupported.
/// `useHardware`: try VideoToolbox for H.264/HEVC. `deinterlace`: bwdif (field-rate) for interlaced video.
TVDecoder *tv_decoder_create(int streamType, int useHardware, int deinterlace);
void tv_decoder_destroy(TVDecoder *dec);

void tv_decoder_set_video_callback(TVDecoder *dec, tv_video_callback cb, void *ctx);
void tv_decoder_set_audio_callback(TVDecoder *dec, tv_audio_callback cb, void *ctx);

/// Audio: 0 = as is (downmix to stereo), 1 = left/main only, 2 = right/sub only (dual-mono).
void tv_decoder_set_dual_mono_mode(TVDecoder *dec, int mode);

/// Feed one PES payload (elementary stream bytes). Decoded output is delivered through callbacks
/// synchronously from this call. Returns 0 or a negative AVERROR.
int tv_decoder_feed(TVDecoder *dec, const uint8_t *data, int size, int64_t pts, int64_t dts);

/// Drop all buffered state (after a discontinuity or channel change).
void tv_decoder_flush(TVDecoder *dec);

/// Human-readable codec name, e.g. "mpeg2video (sw)" / "h264 (VideoToolbox)".
const char *tv_decoder_description(TVDecoder *dec);

#ifdef __cplusplus
}
#endif

#endif
