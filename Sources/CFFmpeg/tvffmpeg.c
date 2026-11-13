#include "tvffmpeg.h"

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <stdio.h>
#include <string.h>

static const AVRational kTB90k = {1, 90000};

struct TVDecoder {
    int streamType;
    int isVideo;
    const AVCodec *codec;
    AVCodecContext *ctx;
    AVCodecParserContext *parser;
    AVPacket *pkt;
    AVFrame *frame;
    AVFrame *filtFrame;

    // Video
    int wantHW, hwActive;
    int deinterlace;
    AVFilterGraph *graph;
    AVFilterContext *src, *sink;
    int gW, gH, gFmt;
    struct SwsContext *sws;
    int sW, sH, sFmt;
    CVPixelBufferPoolRef pool;
    int poolW, poolH;

    // Audio
    SwrContext *swr;
    int swrRate, swrFmt;
    AVChannelLayout swrLayout;
    int dualMono;
    int64_t nextAudioPts; // 90 kHz; expected PTS of the next audio frame
    float *abuf;
    int abufCap;

    tv_video_callback vcb;
    void *vctx;
    tv_audio_callback acb;
    void *actx;
    char desc[96];
};

static int64_t to90k(int64_t ts, AVRational tb) {
    if (ts == AV_NOPTS_VALUE) return TV_NOPTS;
    return av_rescale_q(ts, tb, kTB90k);
}

static enum AVPixelFormat get_format(AVCodecContext *c, const enum AVPixelFormat *fmts) {
    TVDecoder *d = (TVDecoder *)c->opaque;
    const enum AVPixelFormat *p;
    if (d->hwActive) {
        for (p = fmts; *p != AV_PIX_FMT_NONE; p++)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    for (p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*p);
        if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return AV_PIX_FMT_NONE;
}

static int open_codec(TVDecoder *d) {
    enum AVCodecID id;
    switch (d->streamType) {
    case TV_STREAM_MPEG2_VIDEO: id = AV_CODEC_ID_MPEG2VIDEO; d->isVideo = 1; break;
    case TV_STREAM_H264:        id = AV_CODEC_ID_H264;       d->isVideo = 1; break;
    case TV_STREAM_HEVC:        id = AV_CODEC_ID_HEVC;       d->isVideo = 1; break;
    case TV_STREAM_AAC_ADTS:    id = AV_CODEC_ID_AAC;        d->isVideo = 0; break;
    case TV_STREAM_AAC_LATM:    id = AV_CODEC_ID_AAC_LATM;   d->isVideo = 0; break;
    default: return AVERROR_DECODER_NOT_FOUND;
    }
    d->codec = avcodec_find_decoder(id);
    if (!d->codec) return AVERROR_DECODER_NOT_FOUND;
    d->ctx = avcodec_alloc_context3(d->codec);
    if (!d->ctx) return AVERROR(ENOMEM);
    d->ctx->opaque = d;
    d->ctx->pkt_timebase = kTB90k;

    d->hwActive = 0;
    if (d->isVideo && d->wantHW && (id == AV_CODEC_ID_H264 || id == AV_CODEC_ID_HEVC)) {
        AVBufferRef *hw = NULL;
        if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
            d->ctx->hw_device_ctx = hw; // ownership transferred
            d->hwActive = 1;
        }
    }
    if (d->isVideo) {
        d->ctx->get_format = get_format;
        if (!d->hwActive) d->ctx->thread_count = 0; // auto
    }
    int ret = avcodec_open2(d->ctx, d->codec, NULL);
    if (ret < 0) return ret;
    d->parser = av_parser_init(id);
    snprintf(d->desc, sizeof d->desc, "%s (%s)", d->codec->name, d->hwActive ? "VideoToolbox" : "software");
    return 0;
}

TVDecoder *tv_decoder_create(int streamType, int useHardware, int deinterlace) {
    TVDecoder *d = (TVDecoder *)calloc(1, sizeof(TVDecoder));
    if (!d) return NULL;
    d->streamType = streamType;
    d->wantHW = useHardware;
    d->deinterlace = deinterlace;
    d->nextAudioPts = TV_NOPTS;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    d->filtFrame = av_frame_alloc();
    if (!d->pkt || !d->frame || !d->filtFrame || open_codec(d) < 0) {
        tv_decoder_destroy(d);
        return NULL;
    }
    return d;
}

static void free_graph(TVDecoder *d) {
    if (d->graph) avfilter_graph_free(&d->graph);
    d->src = d->sink = NULL;
    d->gW = d->gH = 0;
    d->gFmt = -1;
}

void tv_decoder_destroy(TVDecoder *d) {
    if (!d) return;
    free_graph(d);
    if (d->sws) sws_freeContext(d->sws);
    if (d->pool) CVPixelBufferPoolRelease(d->pool);
    if (d->swr) swr_free(&d->swr);
    av_channel_layout_uninit(&d->swrLayout);
    if (d->parser) av_parser_close(d->parser);
    if (d->ctx) avcodec_free_context(&d->ctx);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    av_frame_free(&d->filtFrame);
    free(d->abuf);
    free(d);
}

void tv_decoder_set_video_callback(TVDecoder *d, tv_video_callback cb, void *ctx) { d->vcb = cb; d->vctx = ctx; }
void tv_decoder_set_audio_callback(TVDecoder *d, tv_audio_callback cb, void *ctx) { d->acb = cb; d->actx = ctx; }
void tv_decoder_set_dual_mono_mode(TVDecoder *d, int mode) { d->dualMono = mode; }
const char *tv_decoder_description(TVDecoder *d) { return d->desc; }

// ---------------------------------------------------------------- video

static void attach_color(CVPixelBufferRef pb, const AVFrame *f) {
    int sd = f->height <= 576;
    CFStringRef matrix = sd ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    if (f->colorspace == AVCOL_SPC_BT709) matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    else if (f->colorspace == AVCOL_SPC_BT2020_NCL) matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
    else if (f->colorspace == AVCOL_SPC_SMPTE170M || f->colorspace == AVCOL_SPC_BT470BG)
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          sd ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

static void attach_par(CVPixelBufferRef pb, AVRational sar) {
    if (sar.num <= 0 || sar.den <= 0) return;
    int h = sar.num, v = sar.den;
    CFNumberRef hn = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    const void *keys[] = {kCVImageBufferPixelAspectRatioHorizontalSpacingKey, kCVImageBufferPixelAspectRatioVerticalSpacingKey};
    const void *vals[] = {hn, vn};
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, dict, kCVAttachmentMode_ShouldPropagate);
    CFRelease(dict);
    CFRelease(hn);
    CFRelease(vn);
}

static int ensure_pool(TVDecoder *d, int w, int h) {
    if (d->pool && d->poolW == w && d->poolH == h) return 0;
    if (d->pool) CVPixelBufferPoolRelease(d->pool);
    d->pool = NULL;
    int fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef wn = CFNumberCreate(NULL, kCFNumberIntType, &w);
    CFNumberRef hn = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef fn = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
    CFDictionaryRef ios = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = {kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferIOSurfacePropertiesKey};
    const void *vals[] = {wn, hn, fn, ios};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVReturn r = CVPixelBufferPoolCreate(NULL, NULL, attrs, &d->pool);
    CFRelease(attrs); CFRelease(ios); CFRelease(fn); CFRelease(hn); CFRelease(wn);
    if (r != kCVReturnSuccess) { d->pool = NULL; return -1; }
    d->poolW = w;
    d->poolH = h;
    return 0;
}

static void emit_software_frame(TVDecoder *d, AVFrame *f, int64_t pts) {
    if (!d->vcb) return;
    int w = f->width, h = f->height;
    if (ensure_pool(d, w, h) < 0) return;
    if (!d->sws || d->sW != w || d->sH != h || d->sFmt != f->format) {
        if (d->sws) sws_freeContext(d->sws);
        d->sws = sws_getContext(w, h, (enum AVPixelFormat)f->format, w, h, AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
        d->sW = w; d->sH = h; d->sFmt = f->format;
        if (!d->sws) return;
    }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, d->pool, &pb) != kCVReturnSuccess) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = {CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), NULL, NULL};
    int dstStride[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 0, 0};
    sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, h, dst, dstStride);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    attach_color(pb, f);
    attach_par(pb, f->sample_aspect_ratio);
    d->vcb(d->vctx, pb, pts, f->sample_aspect_ratio.num, f->sample_aspect_ratio.den);
    CVPixelBufferRelease(pb);
}

static int build_graph(TVDecoder *d, const AVFrame *f) {
    free_graph(d);
    d->graph = avfilter_graph_alloc();
    if (!d->graph) return AVERROR(ENOMEM);
    AVRational sar = f->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = (AVRational){1, 1};
    char args[256];
    snprintf(args, sizeof args, "video_size=%dx%d:pix_fmt=%d:time_base=1/90000:pixel_aspect=%d/%d",
             f->width, f->height, f->format, sar.num, sar.den);
    int ret = avfilter_graph_create_filter(&d->src, avfilter_get_by_name("buffer"), "in", args, NULL, d->graph);
    if (ret < 0) goto fail;
    ret = avfilter_graph_create_filter(&d->sink, avfilter_get_by_name("buffersink"), "out", NULL, NULL, d->graph);
    if (ret < 0) goto fail;
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    outputs->name = av_strdup("in");
    outputs->filter_ctx = d->src;
    outputs->pad_idx = 0;
    outputs->next = NULL;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = d->sink;
    inputs->pad_idx = 0;
    inputs->next = NULL;
    ret = avfilter_graph_parse_ptr(d->graph, "bwdif=mode=send_field:parity=auto:deint=interlaced", &inputs, &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (ret < 0) goto fail;
    ret = avfilter_graph_config(d->graph, NULL);
    if (ret < 0) goto fail;
    d->gW = f->width;
    d->gH = f->height;
    d->gFmt = f->format;
    return 0;
fail:
    free_graph(d);
    return ret;
}

static void handle_video(TVDecoder *d, AVFrame *f) {
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        CVPixelBufferRef pb = (CVPixelBufferRef)f->data[3];
        if (pb && d->vcb) {
            attach_par(pb, f->sample_aspect_ratio);
            d->vcb(d->vctx, pb, to90k(f->best_effort_timestamp, kTB90k), f->sample_aspect_ratio.num, f->sample_aspect_ratio.den);
        }
        return;
    }
    if (!d->deinterlace) {
        emit_software_frame(d, f, to90k(f->best_effort_timestamp, kTB90k));
        return;
    }
    if (!d->graph || d->gW != f->width || d->gH != f->height || d->gFmt != f->format) {
        if (build_graph(d, f) < 0) {
            emit_software_frame(d, f, to90k(f->best_effort_timestamp, kTB90k));
            return;
        }
    }
    f->pts = f->best_effort_timestamp;
    if (av_buffersrc_add_frame_flags(d->src, f, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) return;
    AVRational tb = av_buffersink_get_time_base(d->sink);
    while (av_buffersink_get_frame(d->sink, d->filtFrame) >= 0) {
        emit_software_frame(d, d->filtFrame, to90k(d->filtFrame->pts, tb));
        av_frame_unref(d->filtFrame);
    }
}

// ---------------------------------------------------------------- audio

static void handle_audio(TVDecoder *d, AVFrame *f) {
    if (!d->acb || f->nb_samples <= 0) return;
    if (!d->swr || d->swrRate != f->sample_rate || d->swrFmt != f->format ||
        av_channel_layout_compare(&d->swrLayout, &f->ch_layout) != 0) {
        if (d->swr) swr_free(&d->swr);
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLT, f->sample_rate,
                                &f->ch_layout, (enum AVSampleFormat)f->format, f->sample_rate, 0, NULL) < 0 ||
            swr_init(d->swr) < 0) {
            if (d->swr) swr_free(&d->swr);
            return;
        }
        d->swrRate = f->sample_rate;
        d->swrFmt = f->format;
        av_channel_layout_uninit(&d->swrLayout);
        av_channel_layout_copy(&d->swrLayout, &f->ch_layout);
    }
    int cap = swr_get_out_samples(d->swr, f->nb_samples);
    if (cap <= 0) return;
    if (cap * 2 > d->abufCap) {
        free(d->abuf);
        d->abufCap = cap * 2;
        d->abuf = (float *)malloc(sizeof(float) * d->abufCap);
        if (!d->abuf) { d->abufCap = 0; return; }
    }
    uint8_t *out[1] = {(uint8_t *)d->abuf};
    int n = swr_convert(d->swr, out, cap, (const uint8_t *const *)f->extended_data, f->nb_samples);
    if (n <= 0) return;
    // Dual-mono (二重音声): ISDB carries two mono programs as a 2-channel AAC stream.
    if (d->dualMono && f->ch_layout.nb_channels == 2) {
        for (int i = 0; i < n; i++) {
            float v = d->dualMono == 1 ? d->abuf[i * 2] : d->abuf[i * 2 + 1];
            d->abuf[i * 2] = d->abuf[i * 2 + 1] = v;
        }
    }
    // A PES often carries several AAC frames (ISDB-T: typically 2–4) but only the first gets a
    // PTS from the parser. Stamp the rest by continuing from the previous frame.
    int64_t pts = to90k(f->best_effort_timestamp, kTB90k);
    if (pts == TV_NOPTS) pts = d->nextAudioPts;
    if (pts != TV_NOPTS) d->nextAudioPts = pts + av_rescale(n, 90000, f->sample_rate);
    d->acb(d->actx, d->abuf, n, 2, f->sample_rate, pts);
}

// ---------------------------------------------------------------- feeding

static void decode_packet(TVDecoder *d, AVPacket *pkt) {
    int ret = avcodec_send_packet(d->ctx, pkt);
    for (;;) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r < 0) break;
        if (d->isVideo) handle_video(d, d->frame);
        else handle_audio(d, d->frame);
        av_frame_unref(d->frame);
    }
    if (ret == AVERROR(EAGAIN)) {
        // Output drained above; the packet can go in now.
        if (avcodec_send_packet(d->ctx, pkt) == 0) {
            while (avcodec_receive_frame(d->ctx, d->frame) >= 0) {
                if (d->isVideo) handle_video(d, d->frame);
                else handle_audio(d, d->frame);
                av_frame_unref(d->frame);
            }
        }
    }
}

int tv_decoder_feed(TVDecoder *d, const uint8_t *data, int size, int64_t pts, int64_t dts) {
    int64_t p = pts == TV_NOPTS ? AV_NOPTS_VALUE : pts;
    int64_t q = dts == TV_NOPTS ? AV_NOPTS_VALUE : dts;
    while (size > 0) {
        uint8_t *out = NULL;
        int outSize = 0;
        int len = av_parser_parse2(d->parser, d->ctx, &out, &outSize, data, size, p, q, 0);
        if (len < 0) return len;
        data += len;
        size -= len;
        p = q = AV_NOPTS_VALUE;
        if (outSize > 0) {
            d->pkt->data = out;
            d->pkt->size = outSize;
            d->pkt->pts = d->parser->pts;
            d->pkt->dts = d->parser->dts;
            d->pkt->flags = d->parser->key_frame == 1 ? AV_PKT_FLAG_KEY : 0;
            decode_packet(d, d->pkt);
            d->pkt->data = NULL;
            d->pkt->size = 0;
        }
        if (len == 0 && outSize == 0) break;
    }
    return 0;
}

void tv_decoder_flush(TVDecoder *d) {
    avcodec_flush_buffers(d->ctx);
    d->nextAudioPts = TV_NOPTS;
    if (d->parser) {
        av_parser_close(d->parser);
        d->parser = av_parser_init(d->codec->id);
    }
    free_graph(d);
    if (d->swr) swr_free(&d->swr);
}
