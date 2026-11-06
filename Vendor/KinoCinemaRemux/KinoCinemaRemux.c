/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "KinoCinemaRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/mem.h>

int KinoCinemaRemuxTS(const char *inputPath, const char *outputPath, int (*cancelled)(void)) {
    AVFormatContext *source = NULL;
    AVFormatContext *destination = NULL;
    AVPacket *packet = NULL;
    int *tracks = NULL;
    int result = 0;
    av_log_set_level(AV_LOG_ERROR);

    result = avformat_open_input(&source, inputPath, av_find_input_format("mpegts"), NULL);
    if (result < 0) goto done;
    result = avformat_find_stream_info(source, NULL);
    if (result < 0) goto done;
    result = avformat_alloc_output_context2(&destination, NULL, "mp4", outputPath);
    if (result < 0) goto done;
    const unsigned trackCount = source->nb_streams;
    tracks = av_calloc(trackCount, sizeof(*tracks));
    packet = av_packet_alloc();
    if (!tracks || !packet) {
        result = AVERROR(ENOMEM);
        goto done;
    }

    for (unsigned i = 0; i < trackCount; i++) {
        tracks[i] = -1;
        AVStream *input = source->streams[i];
        enum AVMediaType type = input->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) continue;
        AVStream *output = avformat_new_stream(destination, NULL);
        if (!output) {
            result = AVERROR(ENOMEM);
            goto done;
        }
        result = avcodec_parameters_copy(output->codecpar, input->codecpar);
        if (result < 0) goto done;
        output->codecpar->codec_tag = 0;
        output->time_base = input->time_base;
        av_dict_copy(&output->metadata, input->metadata, 0);
        tracks[i] = output->index;
    }
    if (!destination->nb_streams) {
        result = AVERROR_STREAM_NOT_FOUND;
        goto done;
    }
    destination->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    result = avio_open(&destination->pb, outputPath, AVIO_FLAG_WRITE);
    if (result < 0) goto done;
    result = avformat_write_header(destination, NULL);
    if (result < 0) goto done;
    while ((result = av_read_frame(source, packet)) >= 0) {
        if (cancelled && cancelled()) {
            result = AVERROR_EXIT;
            goto done;
        }
        const unsigned index = packet->stream_index;
        const int mapped = index < trackCount ? tracks[index] : -1;
        if (mapped >= 0) {
            AVStream *input = source->streams[packet->stream_index];
            AVStream *output = destination->streams[mapped];
            av_packet_rescale_ts(packet, input->time_base, output->time_base);
            packet->stream_index = mapped;
            packet->pos = -1;
            result = av_interleaved_write_frame(destination, packet);
            if (result < 0) goto done;
        }
        av_packet_unref(packet);
    }
    if (result == AVERROR_EOF) result = av_write_trailer(destination);

done:
    av_free(tracks);
    av_packet_free(&packet);
    avformat_close_input(&source);
    if (destination) {
        if (destination->pb) avio_closep(&destination->pb);
        avformat_free_context(destination);
    }
    return result;
}
