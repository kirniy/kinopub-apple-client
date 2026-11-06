#ifndef KINO_CINEMA_REMUX_H
#define KINO_CINEMA_REMUX_H

#ifdef __cplusplus
extern "C" {
#endif

/* Copy the video and audio streams from a local MPEG transport stream into MP4. */
__attribute__((visibility("default")))
int KinoCinemaRemuxTS(const char *inputPath, const char *outputPath, int (*cancelled)(void));

#ifdef __cplusplus
}
#endif

#endif
