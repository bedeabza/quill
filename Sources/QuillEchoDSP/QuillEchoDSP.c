#include "QuillEchoDSP.h"
#include "speex/speex_echo.h"
#include <stdlib.h>

struct QuillEcho { SpeexEchoState *state; };
QuillEcho *quill_echo_create(int sample_rate, int frame_size, int filter_samples) {
    if (sample_rate <= 0 || frame_size <= 0 || filter_samples < frame_size) return NULL;
    QuillEcho *echo = calloc(1, sizeof(*echo));
    if (!echo) return NULL;
    echo->state = speex_echo_state_init(frame_size, filter_samples);
    if (!echo->state || speex_echo_ctl(echo->state, SPEEX_ECHO_SET_SAMPLING_RATE, &sample_rate) != 0) {
        quill_echo_destroy(echo);
        return NULL;
    }
    return echo;
}
void quill_echo_process(QuillEcho *echo, const int16_t *microphone, const int16_t *playback, int16_t *clean_microphone) {
    speex_echo_cancellation(echo->state, microphone, playback, clean_microphone);
}
void quill_echo_destroy(QuillEcho *echo) {
    if (!echo) return;
    if (echo->state) speex_echo_state_destroy(echo->state);
    free(echo);
}
