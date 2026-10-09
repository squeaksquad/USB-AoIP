// Dante stage 2 probe: drives the Inferno ALSA plugin the way usb16x16-rt-bridge
// drives a PCM (nonblocking, MMAP_INTERLEAVED, S32, poll, avail_update, delay,
// prepare/start/drop) with no USB involved, and reports what the plan's stage 2
// gates need: the negotiated contract, wake and occupancy behaviour, a thread
// inventory at every lifecycle step, and a sample-for-sample check of a known
// 24-bit pattern returned through the network.
//
// Build on the Pi:  gcc -O2 -Wall -Wextra -o inferno-probe inferno-probe.c -lasound
//
// Pattern: each channel carries its own 24-bit full-period LCG,
//   x' = (x * 1664525 + (2*ch + 1)) mod 2^24, sent as x << 8 in S32.
// Every sample predicts the next, so the capture needs no alignment: a dropped,
// repeated, dithered or re-ordered sample is one mismatch, a hole is a run of
// zeros, and a swapped channel is recognised by its increment. The sequence
// visits every 24-bit value, both full-scale codes included, once per 2^24
// samples (349.5 s at 48 kHz).

#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MAX_CH 64
#define LCG_A 1664525u
#define MASK24 0xFFFFFFu
#define LOCK_RUN 16

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static uint32_t lcg_next(uint32_t x, unsigned ch) { return (x * LCG_A + (2u * ch + 1u)) & MASK24; }

struct options {
    const char *pcm;
    unsigned channels, rate, seconds, linger;
    snd_pcm_uframes_t period, buffer, lead;
    int use_capture, use_playback, use_revents, do_mlock, free_run;
    unsigned xrun_at, xrun_ms;
    const char *dump;
};

struct verify {
    uint32_t prev;
    int have_prev;
    unsigned run;            // consecutive matches
    int locked;
    uint64_t match, mismatch, zero, lowbyte, lock_losses, zero_runs, pos_fs, neg_fs;
    int other_ch;            // last foreign increment that fitted, or -1
    int64_t first_lock_us;
};

static struct verify g_v[MAX_CH];
static unsigned g_mismatch_logged = 0;
static int64_t g_t0;

// ---- thread and memory inventory -------------------------------------------------

static unsigned g_thread_sig = 0;

static long status_kb(const char *key) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    long v = -1;
    size_t n = strlen(key);
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, key, n) && line[n] == ':') { v = strtol(line + n + 1, NULL, 10); break; }
    }
    fclose(f);
    return v;
}

// Prints every thread with its name, scheduling policy and real-time priority.
// Returns a signature of the thread set so the caller can detect changes.
static unsigned thread_inventory(const char *stage, int print) {
    DIR *d = opendir("/proc/self/task");
    if (!d) return 0;
    unsigned sig = 0, count = 0;
    char buf[8192];
    size_t off = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        unsigned tid = (unsigned)strtoul(e->d_name, NULL, 10);
        sig = sig * 31u + tid;
        count++;
        if (!print) continue;
        char path[96], comm[64] = "?", stat[1024];
        snprintf(path, sizeof path, "/proc/self/task/%u/comm", tid);
        FILE *f = fopen(path, "r");
        if (f) { if (fgets(comm, sizeof comm, f)) comm[strcspn(comm, "\n")] = 0; fclose(f); }
        long prio = -1, policy = -1;
        snprintf(path, sizeof path, "/proc/self/task/%u/stat", tid);
        f = fopen(path, "r");
        if (f) {
            if (fgets(stat, sizeof stat, f)) {
                char *p = strrchr(stat, ')');   // fields after the name: state is field 3
                int field = 2;
                for (char *tok = p ? strtok(p + 1, " ") : NULL; tok; tok = strtok(NULL, " ")) {
                    field++;
                    if (field == 40) prio = strtol(tok, NULL, 10);
                    if (field == 41) { policy = strtol(tok, NULL, 10); break; }
                }
            }
            fclose(f);
        }
        const char *pol = policy == 0 ? "OTHER" : policy == 1 ? "FIFO" : policy == 2 ? "RR" : "?";
        if (off < sizeof buf - 128)
            off += (size_t)snprintf(buf + off, sizeof buf - off, " [%u %s %s/%ld]", tid, comm, pol, prio);
    }
    closedir(d);
    if (print) {
        buf[off] = 0;
        printf("THREADS stage=%s t_us=%" PRId64 " count=%u vmlck_kb=%ld vmrss_kb=%ld%s\n", stage,
               now_us() - g_t0, count, status_kb("VmLck"), status_kb("VmRSS"), buf);
        fflush(stdout);
    }
    return sig ^ (count << 24);
}

// ---- PCM setup, as the bridge's Pcm::configure does it -----------------------------

static int check(int rc, const char *what) {
    if (rc < 0) { printf("ERROR %s: %s (%d)\n", what, snd_strerror(rc), rc); fflush(stdout); }
    return rc;
}

static snd_pcm_t *open_pcm(const struct options *o, snd_pcm_stream_t stream, snd_pcm_uframes_t *period,
                           snd_pcm_uframes_t *buffer) {
    const char *dir = stream == SND_PCM_STREAM_CAPTURE ? "capture" : "playback";
    snd_pcm_t *h = NULL;
    int64_t t = now_us();
    if (check(snd_pcm_open(&h, o->pcm, stream, SND_PCM_NONBLOCK), "open") < 0) return NULL;
    printf("OPEN dir=%s us=%" PRId64 "\n", dir, now_us() - t);
    thread_inventory(stream == SND_PCM_STREAM_CAPTURE ? "after-open-capture" : "after-open-playback", 1);

    snd_pcm_hw_params_t *hw;
    snd_pcm_sw_params_t *sw;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_sw_params_alloca(&sw);
    unsigned rate = o->rate;
    int d = 0;
    *period = o->period;
    *buffer = o->buffer;
    if (check(snd_pcm_hw_params_any(h, hw), "hw_params_any") < 0 ||
        check(snd_pcm_hw_params_set_access(h, hw, SND_PCM_ACCESS_MMAP_INTERLEAVED), "MMAP_INTERLEAVED") < 0 ||
        check(snd_pcm_hw_params_set_format(h, hw, SND_PCM_FORMAT_S32_LE), "S32_LE") < 0 ||
        check(snd_pcm_hw_params_set_channels(h, hw, o->channels), "channels") < 0 ||
        check(snd_pcm_hw_params_set_rate_near(h, hw, &rate, &d), "rate") < 0 ||
        check(snd_pcm_hw_params_set_period_size_near(h, hw, period, &d), "period") < 0 ||
        check(snd_pcm_hw_params_set_buffer_size_near(h, hw, buffer), "buffer") < 0)
        return NULL;
    t = now_us();
    if (check(snd_pcm_hw_params(h, hw), "hw_params") < 0) return NULL;
    int64_t hw_us = now_us() - t;
    snd_pcm_hw_params_get_period_size(hw, period, &d);
    snd_pcm_hw_params_get_buffer_size(hw, buffer);

    snd_pcm_uframes_t boundary = 0;
    if (check(snd_pcm_sw_params_current(h, sw), "sw current") < 0 ||
        check(snd_pcm_sw_params_set_avail_min(h, sw, *period), "avail_min") < 0 ||
        check(snd_pcm_sw_params_set_start_threshold(h, sw, stream == SND_PCM_STREAM_PLAYBACK ? *period : 1),
              "start threshold") < 0 ||
        check(snd_pcm_sw_params(h, sw), "sw_params") < 0)
        return NULL;
    snd_pcm_sw_params_get_boundary(sw, &boundary);
    printf("NEGOTIATED dir=%s rate=%u requested_period=%lu period=%lu requested_buffer=%lu buffer=%lu "
           "boundary=%lu hw_params_us=%" PRId64 " poll_fds=%d\n",
           dir, rate, (unsigned long)o->period, (unsigned long)*period, (unsigned long)o->buffer,
           (unsigned long)*buffer, (unsigned long)boundary, hw_us, snd_pcm_poll_descriptors_count(h));

    // hw_params leaves an ioplug prepared already; the bridge then calls prepare() itself.
    thread_inventory(stream == SND_PCM_STREAM_CAPTURE ? "after-hw-params-capture" : "after-hw-params-playback", 1);
    t = now_us();
    int rc = snd_pcm_prepare(h);
    printf("PREPARE dir=%s rc=%d us=%" PRId64 " state=%s\n", dir, rc, now_us() - t,
           snd_pcm_state_name(snd_pcm_state(h)));
    thread_inventory(stream == SND_PCM_STREAM_CAPTURE ? "after-prepare-capture" : "after-prepare-playback", 1);
    if (rc < 0) { check(rc, "prepare"); return NULL; }
    return h;
}

// ---- pattern write and verify --------------------------------------------------------

static uint32_t g_tx_state[MAX_CH];

static void fill(int32_t *dst, snd_pcm_uframes_t frames, unsigned channels, int silence) {
    for (snd_pcm_uframes_t f = 0; f < frames; f++) {
        for (unsigned c = 0; c < channels; c++) {
            if (silence) { dst[f * channels + c] = 0; continue; }
            g_tx_state[c] = lcg_next(g_tx_state[c], c);
            dst[f * channels + c] = (int32_t)(g_tx_state[c] << 8);
        }
    }
}

static void verify(const int32_t *src, snd_pcm_uframes_t frames, unsigned channels, int64_t t_us) {
    for (snd_pcm_uframes_t f = 0; f < frames; f++) {
        for (unsigned c = 0; c < channels; c++) {
            struct verify *v = &g_v[c];
            uint32_t raw = (uint32_t)src[f * channels + c];
            uint32_t x = raw >> 8;
            if (raw & 0xFFu) v->lowbyte++;
            if (!v->have_prev) { v->prev = x; v->have_prev = 1; continue; }
            if (x == lcg_next(v->prev, c)) {
                v->match++;
                if (x == 0x7FFFFFu) v->pos_fs++;
                if (x == 0x800000u) v->neg_fs++;
                if (++v->run == LOCK_RUN && !v->locked) {
                    v->locked = 1;
                    if (!v->first_lock_us) v->first_lock_us = t_us;
                }
            } else if (x == 0 && v->prev == 0) {
                v->zero++;
            } else {
                if (v->locked) {
                    v->lock_losses++;
                    if (x == 0) v->zero_runs++;
                    if (g_mismatch_logged < 40) {
                        g_mismatch_logged++;
                        printf("MISMATCH ch=%u t_us=%" PRId64 " prev=%06x got=%06x expected=%06x low=%02x\n", c + 1,
                               t_us, v->prev, x, lcg_next(v->prev, c), raw & 0xFFu);
                    }
                }
                if (x != 0 || v->locked) v->mismatch++;
                for (unsigned k = 0; k < channels; k++)
                    if (k != c && x == lcg_next(v->prev, k)) v->other_ch = (int)k;
                v->locked = 0;
                v->run = 0;
            }
            v->prev = x;
        }
    }
}

// ---- main ----------------------------------------------------------------------------

static void usage(void) {
    puts("inferno-probe [--pcm NAME] [--channels 16] [--period 64] [--buffer 1024] [--lead FRAMES]\n"
         "              [--seconds 30] [--no-capture] [--no-playback] [--no-revents] [--mlock] [--free-run]\n"
         "              [--xrun-at SECONDS] [--xrun-ms 100] [--linger 12] [--dump FILE]\n"
         "  --no-revents  poll without snd_pcm_poll_descriptors_revents, as the bridge does today\n"
         "  --mlock       mlockall(MCL_CURRENT|MCL_FUTURE) before opening, as the bridge runs\n"
         "  --xrun-at     stop servicing both streams once, then time the recovery\n"
         "  --free-run    never prepare after the first start: when avail exceeds the buffer,\n"
         "                forward the application pointer past the loss and carry on\n"
         "  --linger      seconds to wait after close before the last thread inventory");
}

int main(int argc, char **argv) {
    struct options o = {.pcm = "inferno", .channels = 16, .rate = 48000, .seconds = 30, .linger = 12,
                        .period = 64, .buffer = 1024, .lead = 0, .use_capture = 1, .use_playback = 1,
                        .use_revents = 1, .do_mlock = 0, .free_run = 0, .xrun_at = 0, .xrun_ms = 100, .dump = NULL};
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *n = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--pcm") && n) o.pcm = argv[++i];
        else if (!strcmp(a, "--channels") && n) o.channels = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "--period") && n) o.period = (snd_pcm_uframes_t)atol(argv[++i]);
        else if (!strcmp(a, "--buffer") && n) o.buffer = (snd_pcm_uframes_t)atol(argv[++i]);
        else if (!strcmp(a, "--lead") && n) o.lead = (snd_pcm_uframes_t)atol(argv[++i]);
        else if (!strcmp(a, "--seconds") && n) o.seconds = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "--linger") && n) o.linger = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "--xrun-at") && n) o.xrun_at = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "--xrun-ms") && n) o.xrun_ms = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "--dump") && n) o.dump = argv[++i];
        else if (!strcmp(a, "--no-capture")) o.use_capture = 0;
        else if (!strcmp(a, "--no-playback")) o.use_playback = 0;
        else if (!strcmp(a, "--no-revents")) o.use_revents = 0;
        else if (!strcmp(a, "--mlock")) o.do_mlock = 1;
        else if (!strcmp(a, "--free-run")) o.free_run = 1;
        else { usage(); return 2; }
    }
    if (o.channels == 0 || o.channels > MAX_CH) { usage(); return 2; }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    g_t0 = now_us();
    for (unsigned c = 0; c < MAX_CH; c++) { g_v[c].other_ch = -1; g_tx_state[c] = (c * 0x10000u + 1u) & MASK24; }

    if (o.do_mlock) printf("MLOCK rc=%d\n", mlockall(MCL_CURRENT | MCL_FUTURE));
    thread_inventory("before-open", 1);

    snd_pcm_t *cap = NULL, *play = NULL;
    snd_pcm_uframes_t cap_period = 0, cap_buffer = 0, play_period = 0, play_buffer = 0;
    // Capture first, as the bridge opens its capture side before it starts playback.
    if (o.use_capture && !(cap = open_pcm(&o, SND_PCM_STREAM_CAPTURE, &cap_period, &cap_buffer))) return 1;
    if (o.use_playback && !(play = open_pcm(&o, SND_PCM_STREAM_PLAYBACK, &play_period, &play_buffer))) return 1;
    if (!o.lead) o.lead = 2 * (play ? play_period : o.period);

    struct pollfd fds[8];
    int nfds = 0, cap_fds = 0, play_fds = 0;
    if (cap) { cap_fds = snd_pcm_poll_descriptors(cap, fds, 4); nfds += cap_fds > 0 ? cap_fds : 0; }
    if (play) { play_fds = snd_pcm_poll_descriptors(play, fds + nfds, 4); nfds += play_fds > 0 ? play_fds : 0; }

    FILE *dump = o.dump ? fopen(o.dump, "wb") : NULL;

    if (cap) {
        int64_t t = now_us();
        int rc = snd_pcm_start(cap);
        printf("START dir=capture rc=%d us=%" PRId64 " state=%s\n", rc, now_us() - t,
               snd_pcm_state_name(snd_pcm_state(cap)));
    }
    thread_inventory("after-start", 1);
    g_thread_sig = thread_inventory("", 0);

    int64_t start = now_us(), next_report = start + 1000000, last_wake = start;
    int64_t max_gap = 0, xrun_from = 0, xrun_until = 0;
    uint64_t wakes = 0, spins = 0, cap_frames = 0, play_frames = 0, cap_err = 0, play_err = 0;
    uint64_t tot_cap = 0, tot_play = 0, tot_cap_err = 0, tot_play_err = 0, thread_changes = 0;
    uint64_t cap_resyncs = 0, play_resyncs = 0, cap_lost = 0, play_lost = 0;
    snd_pcm_sframes_t cap_avail_min = 0, cap_avail_max = 0, play_delay_min = 0, play_delay_max = 0;
    int have_stats = 0, xrun_done = 0;

    while (!g_stop && now_us() - start < (int64_t)o.seconds * 1000000) {
        int pr = poll(fds, (nfds_t)nfds, 100);
        int64_t t = now_us();
        if (pr > 0 && o.use_revents) {
            unsigned short rev = 0;
            if (cap && cap_fds > 0) snd_pcm_poll_descriptors_revents(cap, fds, (unsigned)cap_fds, &rev);
            if (play && play_fds > 0)
                snd_pcm_poll_descriptors_revents(play, fds + (cap_fds > 0 ? cap_fds : 0), (unsigned)play_fds, &rev);
        }
        wakes++;
        if (t - last_wake < 50) spins++;   // woke again inside 50 us: the descriptor was still readable
        if (t - last_wake > max_gap) max_gap = t - last_wake;
        last_wake = t;

        if (o.xrun_at && !xrun_done && t - start >= (int64_t)o.xrun_at * 1000000) {
            xrun_done = 1;
            xrun_from = t;
            xrun_until = t + (int64_t)o.xrun_ms * 1000;
            printf("XRUN-TEST begin t_us=%" PRId64 " hold_ms=%u\n", t - g_t0, o.xrun_ms);
        }
        int holding = xrun_until && t < xrun_until;
        if (xrun_until && !holding) {
            xrun_until = 0;
            printf("XRUN-TEST end held_us=%" PRId64 "\n", t - xrun_from);
        }
        if (holding) continue;

        if (cap) {
            snd_pcm_sframes_t avail = snd_pcm_avail_update(cap);
            if (avail < 0 && o.free_run) {
                if (!cap_err++) printf("FREERUN-FAILED dir=capture code=%ld (%s) state=%s t_us=%" PRId64 "\n", (long)avail,
                                       snd_strerror((int)avail), snd_pcm_state_name(snd_pcm_state(cap)), t - g_t0);
            } else if (avail < 0) {
                cap_err++;
                printf("RECOVER dir=capture code=%ld (%s) state=%s t_us=%" PRId64 "\n", (long)avail,
                       snd_strerror((int)avail), snd_pcm_state_name(snd_pcm_state(cap)), t - g_t0);
                int64_t a = now_us();
                snd_pcm_drop(cap);
                int rp = snd_pcm_prepare(cap);
                int64_t b = now_us();
                int rs = snd_pcm_start(cap);
                printf("RECOVERED dir=capture prepare_rc=%d prepare_us=%" PRId64 " start_rc=%d start_us=%" PRId64 "\n",
                       rp, b - a, rs, now_us() - b);
                thread_inventory("after-recover-capture", 1);
                g_thread_sig = thread_inventory("", 0);
                for (unsigned c = 0; c < o.channels; c++) { g_v[c].have_prev = 0; g_v[c].locked = 0; g_v[c].run = 0; }
            } else {
                if (o.free_run && (snd_pcm_uframes_t)avail > cap_buffer) {
                    // The plugin does not report a capture overrun: the ring has been lapped and
                    // only the newest frames are what they claim to be. Keep one period of them.
                    snd_pcm_uframes_t skip = (snd_pcm_uframes_t)avail - cap_period;
                    snd_pcm_sframes_t fw = snd_pcm_forward(cap, skip);
                    cap_resyncs++;
                    if (fw > 0) cap_lost += (uint64_t)fw;
                    printf("NETRESYNC dir=capture avail=%ld buffer=%lu forward=%ld state=%s t_us=%" PRId64 "\n",
                           (long)avail, (unsigned long)cap_buffer, (long)fw,
                           snd_pcm_state_name(snd_pcm_state(cap)), t - g_t0);
                    thread_inventory("after-resync-capture", 1);
                    for (unsigned c = 0; c < o.channels; c++) { g_v[c].have_prev = 0; g_v[c].locked = 0; g_v[c].run = 0; }
                    avail = fw >= 0 ? avail - fw : avail;
                }
                if (!have_stats || avail < cap_avail_min) cap_avail_min = avail;
                if (!have_stats || avail > cap_avail_max) cap_avail_max = avail;
                while (avail > 0) {
                    const snd_pcm_channel_area_t *areas;
                    snd_pcm_uframes_t off, frames = (snd_pcm_uframes_t)avail;
                    if (snd_pcm_mmap_begin(cap, &areas, &off, &frames) < 0 || frames == 0) break;
                    const int32_t *p = (const int32_t *)((const char *)areas[0].addr + (areas[0].first / 8) +
                                                         off * (areas[0].step / 8));
                    verify(p, frames, o.channels, t - g_t0);
                    if (dump) fwrite(p, sizeof(int32_t) * o.channels, frames, dump);
                    snd_pcm_sframes_t done = snd_pcm_mmap_commit(cap, off, frames);
                    if (done <= 0) break;
                    cap_frames += (uint64_t)done;
                    avail -= done;
                }
            }
        }

        if (play) {
            snd_pcm_sframes_t avail = snd_pcm_avail_update(play);
            if (avail < 0 && o.free_run) {
                // Free-run never prepares. With the stock plugin this is reached once the
                // pointer callback has returned -EPIPE (outside its start-up grace window).
                if (!play_err++) printf("FREERUN-FAILED dir=playback code=%ld (%s) state=%s t_us=%" PRId64 "\n", (long)avail,
                                        snd_strerror((int)avail), snd_pcm_state_name(snd_pcm_state(play)), t - g_t0);
            } else if (avail < 0) {
                play_err++;
                printf("RECOVER dir=playback code=%ld (%s) state=%s t_us=%" PRId64 "\n", (long)avail,
                       snd_strerror((int)avail), snd_pcm_state_name(snd_pcm_state(play)), t - g_t0);
                int64_t a = now_us();
                snd_pcm_drop(play);
                int rp = snd_pcm_prepare(play);
                printf("RECOVERED dir=playback prepare_rc=%d prepare_us=%" PRId64 "\n", rp, now_us() - a);
                thread_inventory("after-recover-playback", 1);
                g_thread_sig = thread_inventory("", 0);
            } else {
                if (o.free_run && (snd_pcm_uframes_t)avail > play_buffer) {
                    // The clock has passed the application pointer by the excess. Move the
                    // pointer up to the clock; the lead is written below as on any other wake.
                    snd_pcm_uframes_t deficit = (snd_pcm_uframes_t)avail - play_buffer;
                    snd_pcm_sframes_t fw = snd_pcm_forward(play, deficit);
                    play_resyncs++;
                    if (fw > 0) play_lost += (uint64_t)fw;
                    printf("NETRESYNC dir=playback avail=%ld buffer=%lu forward=%ld state=%s t_us=%" PRId64 "\n",
                           (long)avail, (unsigned long)play_buffer, (long)fw,
                           snd_pcm_state_name(snd_pcm_state(play)), t - g_t0);
                    thread_inventory("after-resync-playback", 1);
                    avail = snd_pcm_avail_update(play);
                    if (avail < 0) { printf("ERROR avail after resync: %ld\n", (long)avail); avail = 0; }
                }
                snd_pcm_sframes_t delay = 0;
                int have_delay = snd_pcm_delay(play, &delay) == 0;
                snd_pcm_sframes_t queued = (snd_pcm_sframes_t)play_buffer - avail;
                if (have_delay) {
                    if (!have_stats || delay < play_delay_min) play_delay_min = delay;
                    if (!have_stats || delay > play_delay_max) play_delay_max = delay;
                }
                snd_pcm_sframes_t want = (snd_pcm_sframes_t)o.lead - queued;
                if (want > avail) want = avail;
                while (want > 0) {
                    const snd_pcm_channel_area_t *areas;
                    snd_pcm_uframes_t off, frames = (snd_pcm_uframes_t)want;
                    if (snd_pcm_mmap_begin(play, &areas, &off, &frames) < 0 || frames == 0) break;
                    int32_t *p = (int32_t *)((char *)areas[0].addr + (areas[0].first / 8) + off * (areas[0].step / 8));
                    fill(p, frames, o.channels, 0);
                    snd_pcm_sframes_t done = snd_pcm_mmap_commit(play, off, frames);
                    if (done <= 0) break;
                    play_frames += (uint64_t)done;
                    want -= done;
                }
                if (snd_pcm_state(play) == SND_PCM_STATE_PREPARED && play_frames >= play_period) {
                    int64_t a = now_us();
                    int rs = snd_pcm_start(play);
                    printf("START dir=playback rc=%d us=%" PRId64 " state=%s\n", rs, now_us() - a,
                           snd_pcm_state_name(snd_pcm_state(play)));
                    thread_inventory("after-start-playback", 1);
                    g_thread_sig = thread_inventory("", 0);
                }
            }
        }
        have_stats = 1;

        if (t >= next_report) {
            unsigned sig = thread_inventory("", 0);
            if (sig != g_thread_sig) {
                thread_changes++;
                g_thread_sig = sig;
                thread_inventory("CHANGED-while-running", 1);
            }
            unsigned locked = 0;
            uint64_t mism = 0, zero = 0, low = 0;
            for (unsigned c = 0; c < o.channels; c++) {
                locked += (unsigned)g_v[c].locked;
                mism += g_v[c].mismatch; zero += g_v[c].zero; low += g_v[c].lowbyte;
            }
            printf("PROBE t=%.1f wakes=%" PRIu64 " spins=%" PRIu64 " max_gap_us=%" PRId64 " cap_frames=%" PRIu64
                   " play_frames=%" PRIu64 " cap_avail=%ld..%ld play_delay=%ld..%ld cap_err=%" PRIu64
                   " play_err=%" PRIu64 " locked=%u/%u mismatch=%" PRIu64 " zeros=%" PRIu64 " lowbyte=%" PRIu64 "\n",
                   (double)(t - start) / 1e6, wakes, spins, max_gap, cap_frames, play_frames, (long)cap_avail_min,
                   (long)cap_avail_max, (long)play_delay_min, (long)play_delay_max, cap_err, play_err, locked,
                   o.channels, mism, zero, low);
            fflush(stdout);
            tot_cap += cap_frames; tot_play += play_frames; tot_cap_err += cap_err; tot_play_err += play_err;
            wakes = spins = cap_frames = play_frames = cap_err = play_err = 0;
            max_gap = 0;
            have_stats = 0;
            next_report += 1000000;
        }
    }
    tot_cap += cap_frames; tot_play += play_frames; tot_cap_err += cap_err; tot_play_err += play_err;
    double elapsed = (double)(now_us() - start) / 1e6;

    for (unsigned c = 0; c < o.channels && cap; c++) {
        const struct verify *v = &g_v[c];
        printf("VERIFY ch=%u match=%" PRIu64 " mismatch=%" PRIu64 " lock_losses=%" PRIu64 " zero_runs=%" PRIu64
               " zeros=%" PRIu64 " lowbyte_nonzero=%" PRIu64 " pos_fs=%" PRIu64 " neg_fs=%" PRIu64
               " first_lock_us=%" PRId64 " other_channel=%d\n",
               c + 1, v->match, v->mismatch, v->lock_losses, v->zero_runs, v->zero, v->lowbyte, v->pos_fs, v->neg_fs,
               v->first_lock_us, v->other_ch < 0 ? 0 : v->other_ch + 1);
    }
    printf("SUMMARY seconds=%.2f cap_frames=%" PRIu64 " play_frames=%" PRIu64 " cap_rate=%.3f play_rate=%.3f "
           "cap_recovers=%" PRIu64 " play_recovers=%" PRIu64 " thread_changes=%" PRIu64 " revents=%d mlock=%d "
           "free_run=%d cap_resyncs=%" PRIu64 " cap_lost=%" PRIu64 " play_resyncs=%" PRIu64 " play_lost=%" PRIu64 "\n",
           elapsed, tot_cap, tot_play, elapsed > 0 ? (double)tot_cap / elapsed : 0,
           elapsed > 0 ? (double)tot_play / elapsed : 0, tot_cap_err, tot_play_err, thread_changes, o.use_revents,
           o.do_mlock, o.free_run, cap_resyncs, cap_lost, play_resyncs, play_lost);

    thread_inventory("before-close", 1);
    if (play) { int64_t t = now_us(); snd_pcm_drop(play); snd_pcm_close(play); printf("CLOSE dir=playback us=%" PRId64 "\n", now_us() - t); }
    thread_inventory("after-close-playback", 1);
    if (cap) { int64_t t = now_us(); snd_pcm_drop(cap); snd_pcm_close(cap); printf("CLOSE dir=capture us=%" PRId64 "\n", now_us() - t); }
    thread_inventory("after-close-capture", 1);
    if (dump) fclose(dump);
    if (o.linger) { sleep(o.linger); thread_inventory("after-linger", 1); }
    return 0;
}
