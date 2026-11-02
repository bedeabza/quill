#ifndef QUILL_ECHO_DSP_H
#define QUILL_ECHO_DSP_H
#include <stdint.h>
typedef struct QuillEcho QuillEcho;
QuillEcho *quill_echo_create(int sample_rate, int frame_size, int filter_samples);
void quill_echo_process(QuillEcho *state, const int16_t *microphone, const int16_t *playback, int16_t *clean_microphone);
void quill_echo_destroy(QuillEcho *state);
#endif
