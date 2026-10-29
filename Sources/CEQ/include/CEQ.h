#ifndef CEQ_H
#define CEQ_H
#include <stdint.h>
typedef struct RPEQ RPEQ;
RPEQ *rp_eq_create(void);
void rp_eq_destroy(RPEQ *eq);
void rp_eq_set(RPEQ *eq, int enabled, float preamp, const float *bands);
void rp_eq_volume(RPEQ *eq, float volume);
/// Left/right balance, -1 (left only) to 1 (right only). Turns down the opposite channel; 0 leaves both untouched.
void rp_eq_balance(RPEQ *eq, float balance);
/// Total channels in the stream, so a lone mono buffer is not mistaken for the left channel. 0 infers it from each call.
void rp_eq_channels(RPEQ *eq, uint32_t channels);
void rp_eq_prepare(RPEQ *eq, double sampleRate);
void rp_eq_process(RPEQ *eq, float *data, uint32_t frames, uint32_t channels, uint32_t firstChannel);
double rp_eq_rate(RPEQ *eq);
/// Copies the newest `count` mono samples (oldest first, zero-padded when fewer exist). Count must be <= 4096.
uint32_t rp_vis_read(RPEQ *eq, float *out, uint32_t count);
/// Loudness leveler: steers the output toward a fixed average level. `rp_level_db` is the gain it currently applies.
void rp_level_set(RPEQ *eq, int enabled);
double rp_level_db(RPEQ *eq);
uint64_t rp_eq_frames(RPEQ *eq);
double rp_eq_ratio(RPEQ *eq);
#endif
