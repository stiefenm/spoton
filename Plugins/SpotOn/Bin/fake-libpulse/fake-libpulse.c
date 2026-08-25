/*
 * fake-libpulse.c -- PulseAudio client API stub for Spotify Soloist
 *
 * SpotOn v4.0 (Soloist Integration), Phase 71 Plan 04, decision D-06.
 *
 * Spike-validated (.planning/ROADMAP.md "v4.0 Spike Results" and
 * .planning/phases/71-soloist-foundation/71-RESEARCH.md, Architecture
 * Patterns / Common Pitfalls #3): the Soloist binary dlopen()s
 * "libpulse.so.0" at runtime and dlsym()s the ~47 pa_* symbols
 * implemented below. This exact symbol set was derived from a real
 * Soloist binary this session (`nm -D soloist`, cross-checked with
 * `strings soloist | grep '^pa_'`) -- not guessed -- per Task 1's
 * precondition.
 *
 * Soloist never talks to a real PulseAudio server: this shared object
 * satisfies its entire PulseAudio dynamic-symbol surface in-process,
 * so Soloist's threaded mainloop and context/stream state machine run
 * to completion exactly as if a real server were connected and ready
 * to play. Every function below returns a plausible, synchronous
 * success/state value -- there is no real async dispatch because
 * there is nothing to wait for (no real audio subsystem).
 *
 * The single load-bearing function is pa_stream_write(): it receives
 * the PCM buffer Soloist itself already encoded (S32LE, 44100 Hz,
 * 2 channels -- see ROADMAP.md "Audio Interface" spike result) and
 * forwards those bytes verbatim to an output file descriptor. This
 * stub does not decode, resample, or otherwise touch the audio data.
 *
 * PCM output target (resolved once, lazily, on first pa_stream_write()
 * call):
 *   1. SPOTON_SOLOIST_PCM_FD   -- an already-open file descriptor
 *      number (e.g. inherited from the parent process); used as-is.
 *   2. SPOTON_SOLOIST_PCM_PATH -- a filesystem path, opened
 *      O_WRONLY|O_CREAT|O_TRUNC, mode 0600.
 *   3. Fallback: STDOUT_FILENO (1) -- keeps this library self-
 *      contained for standalone/manual testing without either env
 *      var set.
 * Phase 72 (LMS StreamServer coupling) is expected to set one of
 * these two env vars before spawning the Soloist daemon process.
 *
 * This file references no external or private paths -- it ships
 * inside the public SpotOn plugin zip (Bin/<arch>/libpulse.so.0 via
 * the CI cross-compile matrix, D-06).
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

/* WR-02: on Linux, write() to a pipe whose read end is closed delivers
 * SIGPIPE, whose default disposition terminates the process -- the
 * `w < 0` / errno == EPIPE branch in pa_stream_write() below is
 * otherwise unreachable, and the "drop the remainder, keep Soloist
 * alive" graceful-degradation path documented there is dead code.
 * Ignore SIGPIPE from this stub itself so write() returns EPIPE as
 * that code already expects, regardless of whether the Soloist binary
 * (closed-source, unverified) ignores/resets it itself. Constructor
 * runs once at dlopen() time, before Soloist calls into any pa_*
 * symbol. */
__attribute__((constructor))
static void _fake_libpulse_init(void) {
    signal(SIGPIPE, SIG_IGN);
}

/* ------------------------------------------------------------------ */
/* Public PulseAudio types this stub must reproduce byte-for-byte,    */
/* because Soloist (compiled against the real pulse headers)          */
/* constructs or reads these structs directly rather than through an  */
/* accessor function we control.                                     */
/* ------------------------------------------------------------------ */

typedef uint64_t pa_usec_t;
typedef uint32_t pa_volume_t;

#define PA_CHANNELS_MAX 32

/* [pulse/sample.h] -- Soloist constructs this on the stack and passes
 * a pointer into pa_stream_new()/pa_stream_new_with_proplist(). */
typedef enum pa_sample_format {
    PA_SAMPLE_U8,
    PA_SAMPLE_ALAW,
    PA_SAMPLE_ULAW,
    PA_SAMPLE_S16LE,
    PA_SAMPLE_S16BE,
    PA_SAMPLE_FLOAT32LE,
    PA_SAMPLE_FLOAT32BE,
    PA_SAMPLE_S32LE,
    PA_SAMPLE_S32BE,
    PA_SAMPLE_S24LE,
    PA_SAMPLE_S24BE,
    PA_SAMPLE_S24_32LE,
    PA_SAMPLE_S24_32BE,
    PA_SAMPLE_MAX,
    PA_SAMPLE_INVALID = -1
} pa_sample_format_t;

typedef struct pa_sample_spec {
    pa_sample_format_t format;
    uint32_t rate;
    uint8_t channels;
} pa_sample_spec;

/* [pulse/volume.h] -- likewise stack-constructed by Soloist and
 * passed by pointer into pa_cvolume_set()/pa_cvolume_avg(). */
typedef struct pa_cvolume {
    uint8_t channels;
    pa_volume_t values[PA_CHANNELS_MAX];
} pa_cvolume;

/* [pulse/def.h] -- returned BY US to Soloist via
 * pa_stream_get_timing_info(); Soloist reads its fields directly, so
 * the layout must match the public PulseAudio API definition. */
typedef struct pa_timing_info {
    struct timeval timestamp;
    int synchronized_clocks;
    pa_usec_t sink_usec;
    pa_usec_t source_usec;
    pa_usec_t transport_usec;
    int playing;
    int write_index_corrupt;
    int64_t write_index;
    int read_index_corrupt;
    int64_t read_index;
    pa_usec_t configured_sink_usec;
    pa_usec_t configured_source_usec;
    int64_t since_underrun;
} pa_timing_info;

/* Opaque real-API types this stub never dereferences (only ever
 * passed through as pointers) -- forward-declared, never defined. */
typedef struct pa_channel_map pa_channel_map;
typedef struct pa_buffer_attr pa_buffer_attr;
typedef struct pa_mainloop_api pa_mainloop_api;
typedef struct pa_spawn_api pa_spawn_api;
typedef struct pa_sink_input_info pa_sink_input_info;

/* Enums whose exact values Soloist never inspects through us (it
 * only ever passes them straight through as opaque ints). */
typedef int pa_context_flags_t;
typedef int pa_stream_flags_t;
typedef int pa_seek_mode_t;
typedef int pa_subscription_mask_t;
typedef int pa_subscription_event_type_t;

typedef enum pa_context_state {
    PA_CONTEXT_UNCONNECTED,
    PA_CONTEXT_CONNECTING,
    PA_CONTEXT_AUTHORIZING,
    PA_CONTEXT_SETTING_NAME,
    PA_CONTEXT_READY,
    PA_CONTEXT_FAILED,
    PA_CONTEXT_TERMINATED
} pa_context_state_t;

typedef enum pa_stream_state {
    PA_STREAM_UNCONNECTED,
    PA_STREAM_CREATING,
    PA_STREAM_READY,
    PA_STREAM_FAILED,
    PA_STREAM_TERMINATED
} pa_stream_state_t;

typedef enum pa_operation_state {
    PA_OPERATION_RUNNING,
    PA_OPERATION_DONE,
    PA_OPERATION_CANCELLED
} pa_operation_state_t;

/* Our own internal (fully opaque to Soloist) handle types. */
typedef struct pa_threaded_mainloop pa_threaded_mainloop;
typedef struct pa_context pa_context;
typedef struct pa_stream pa_stream;
typedef struct pa_operation pa_operation;
typedef struct pa_proplist pa_proplist;

/* Callback typedefs, matching the real API's function-pointer shapes. */
typedef void (*pa_context_notify_cb_t)(pa_context *c, void *userdata);
typedef void (*pa_context_success_cb_t)(pa_context *c, int success, void *userdata);
typedef void (*pa_context_subscribe_cb_t)(pa_context *c, pa_subscription_event_type_t t, uint32_t idx, void *userdata);
typedef void (*pa_sink_input_info_cb_t)(pa_context *c, const pa_sink_input_info *i, int eol, void *userdata);
typedef void (*pa_stream_notify_cb_t)(pa_stream *s, void *userdata);
typedef void (*pa_stream_success_cb_t)(pa_stream *s, int success, void *userdata);
typedef void (*pa_free_cb_t)(void *p);

/* ------------------------------------------------------------------ */
/* Internal object definitions (our layout, never inspected by        */
/* Soloist directly -- always accessed through the functions below).  */
/* ------------------------------------------------------------------ */

struct pa_threaded_mainloop {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    pthread_t       thread;
    int             running;
    int             started;
};

struct pa_context {
    pa_context_state_t        state;
    pa_context_notify_cb_t    state_cb;
    void                      *state_userdata;
    pa_context_subscribe_cb_t subscribe_cb;
    void                      *subscribe_userdata;
    pa_threaded_mainloop      *mainloop; /* for signal() after state change */
};

struct pa_stream {
    pa_context             *context;
    pa_stream_state_t       state;
    pa_stream_notify_cb_t   state_cb;
    void                    *state_userdata;
    pa_stream_notify_cb_t   started_cb;
    void                    *started_userdata;
    pa_stream_notify_cb_t   underflow_cb;
    void                    *underflow_userdata;
    pa_sample_spec          sample_spec;
    uint32_t                index;
    int                     corked;
    int64_t                 bytes_written;
    pa_timing_info          timing;
};

struct pa_operation {
    pa_operation_state_t state;
};

struct pa_proplist {
    int unused;
};

static uint32_t next_stream_index = 1;

/* ------------------------------------------------------------------ */
/* PCM output target resolution (see file header).                    */
/* ------------------------------------------------------------------ */

static int pcm_output_fd = -2; /* -2 = unresolved, >=0 = ready */

static int _pcm_output_fd(void) {
    if (pcm_output_fd != -2) {
        return pcm_output_fd;
    }

    const char *fdEnv = getenv("SPOTON_SOLOIST_PCM_FD");
    if (fdEnv && *fdEnv) {
        char *end = NULL;
        long v = strtol(fdEnv, &end, 10);
        if (end && *end == '\0' && v >= 0) {
            pcm_output_fd = (int)v;
            return pcm_output_fd;
        }
    }

    const char *pathEnv = getenv("SPOTON_SOLOIST_PCM_PATH");
    if (pathEnv && *pathEnv) {
        int fd = open(pathEnv, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            pcm_output_fd = fd;
            return pcm_output_fd;
        }
    }

    pcm_output_fd = STDOUT_FILENO;
    return pcm_output_fd;
}

/* ------------------------------------------------------------------ */
/* Internal state-transition helpers.                                 */
/* ------------------------------------------------------------------ */

static void _context_set_state(pa_context *c, pa_context_state_t s) {
    if (!c) {
        return;
    }
    c->state = s;
    if (c->state_cb) {
        c->state_cb(c, c->state_userdata);
    }
    if (c->mainloop) {
        pthread_cond_broadcast(&c->mainloop->cond);
    }
}

static void _stream_set_state(pa_stream *s, pa_stream_state_t st) {
    if (!s) {
        return;
    }
    s->state = st;
    if (s->state_cb) {
        s->state_cb(s, s->state_userdata);
    }
    if (s->context && s->context->mainloop) {
        pthread_cond_broadcast(&s->context->mainloop->cond);
    }
}

static void _stream_refresh_timing(pa_stream *s) {
    struct timeval now;
    gettimeofday(&now, NULL);
    memset(&s->timing, 0, sizeof(s->timing));
    s->timing.timestamp = now;
    s->timing.synchronized_clocks = 1;
    s->timing.playing = s->corked ? 0 : 1;
    /* No real sink buffer to lag behind -- report the write index as
     * already fully drained (read == write) since bytes handed to
     * pa_stream_write() are forwarded to the output FD synchronously. */
    s->timing.write_index = s->bytes_written;
    s->timing.read_index = s->bytes_written;
}

static pa_operation *_operation_new_done(void) {
    pa_operation *o = calloc(1, sizeof(*o));
    if (o) {
        o->state = PA_OPERATION_DONE;
    }
    return o;
}

/* ==================================================================== */
/* pulse/thread-mainloop.h                                              */
/* ==================================================================== */

pa_threaded_mainloop *pa_threaded_mainloop_new(void) {
    pa_threaded_mainloop *m = calloc(1, sizeof(*m));
    if (!m) {
        return NULL;
    }
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&m->lock, &attr);
    pthread_mutexattr_destroy(&attr);
    pthread_cond_init(&m->cond, NULL);
    return m;
}

void pa_threaded_mainloop_free(pa_threaded_mainloop *m) {
    if (!m) {
        return;
    }
    pthread_cond_destroy(&m->cond);
    pthread_mutex_destroy(&m->lock);
    free(m);
}

/* No real event source to dispatch: every pa_* call in this stub
 * completes synchronously (with the appropriate signal/broadcast)
 * under the caller's own lock/wait protocol. This thread exists only
 * so pa_threaded_mainloop_start()/stop() behave like a real joinable
 * worker thread. */
static void *_mainloop_thread_fn(void *arg) {
    pa_threaded_mainloop *m = (pa_threaded_mainloop *)arg;
    pthread_mutex_lock(&m->lock);
    while (m->running) {
        pthread_cond_wait(&m->cond, &m->lock);
    }
    pthread_mutex_unlock(&m->lock);
    return NULL;
}

int pa_threaded_mainloop_start(pa_threaded_mainloop *m) {
    if (!m) {
        return -1;
    }
    m->running = 1;
    if (pthread_create(&m->thread, NULL, _mainloop_thread_fn, m) != 0) {
        m->running = 0;
        return -1;
    }
    m->started = 1;
    return 0;
}

void pa_threaded_mainloop_stop(pa_threaded_mainloop *m) {
    if (!m || !m->started) {
        return;
    }
    pthread_mutex_lock(&m->lock);
    m->running = 0;
    pthread_cond_broadcast(&m->cond);
    pthread_mutex_unlock(&m->lock);
    pthread_join(m->thread, NULL);
    m->started = 0;
}

void pa_threaded_mainloop_lock(pa_threaded_mainloop *m) {
    if (m) {
        pthread_mutex_lock(&m->lock);
    }
}

void pa_threaded_mainloop_unlock(pa_threaded_mainloop *m) {
    if (m) {
        pthread_mutex_unlock(&m->lock);
    }
}

void pa_threaded_mainloop_wait(pa_threaded_mainloop *m) {
    if (m) {
        pthread_cond_wait(&m->cond, &m->lock);
    }
}

void pa_threaded_mainloop_signal(pa_threaded_mainloop *m, int wait_for_accept) {
    (void)wait_for_accept;
    if (m) {
        pthread_cond_broadcast(&m->cond);
    }
}

pa_mainloop_api *pa_threaded_mainloop_get_api(pa_threaded_mainloop *m) {
    /* No real pa_mainloop_api implementation needed (see
     * _mainloop_thread_fn) -- return a non-NULL sentinel so any
     * NULL-check in Soloist's code succeeds. Soloist never
     * dereferences this pointer itself; it only hands it back to
     * pa_context_new() below, which we do control. */
    return (pa_mainloop_api *)m;
}

/* ==================================================================== */
/* pulse/context.h                                                      */
/* ==================================================================== */

pa_context *pa_context_new(pa_mainloop_api *mainloop, const char *name) {
    (void)name;
    pa_context *c = calloc(1, sizeof(*c));
    if (!c) {
        return NULL;
    }
    c->state = PA_CONTEXT_UNCONNECTED;
    c->mainloop = (pa_threaded_mainloop *)mainloop;
    return c;
}

void pa_context_unref(pa_context *c) {
    free(c);
}

void pa_context_set_state_callback(pa_context *c, pa_context_notify_cb_t cb, void *userdata) {
    if (!c) {
        return;
    }
    c->state_cb = cb;
    c->state_userdata = userdata;
}

void pa_context_set_subscribe_callback(pa_context *c, pa_context_subscribe_cb_t cb, void *userdata) {
    if (!c) {
        return;
    }
    c->subscribe_cb = cb;
    c->subscribe_userdata = userdata;
}

int pa_context_errno(const pa_context *c) {
    (void)c;
    return 0; /* stub never fails */
}

pa_context_state_t pa_context_get_state(const pa_context *c) {
    return c ? c->state : PA_CONTEXT_UNCONNECTED;
}

int pa_context_connect(pa_context *c, const char *server, pa_context_flags_t flags, const pa_spawn_api *api) {
    (void)server;
    (void)flags;
    (void)api;
    if (!c) {
        return -1;
    }
    /* Real PulseAudio transitions CONNECTING -> AUTHORIZING ->
     * SETTING_NAME -> READY asynchronously; this stub has no server
     * round-trip to wait for, so it settles directly on READY. */
    _context_set_state(c, PA_CONTEXT_READY);
    return 0;
}

void pa_context_disconnect(pa_context *c) {
    _context_set_state(c, PA_CONTEXT_TERMINATED);
}

/* ==================================================================== */
/* pulse/subscribe.h + pulse/introspect.h                               */
/* ==================================================================== */

pa_operation *pa_context_subscribe(pa_context *c, pa_subscription_mask_t m, pa_context_success_cb_t cb, void *userdata) {
    (void)m;
    if (cb) {
        cb(c, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_context_get_sink_input_info(pa_context *c, uint32_t idx, pa_sink_input_info_cb_t cb, void *userdata) {
    (void)idx;
    if (cb) {
        /* No real sink-input list exists -- signal end-of-list
         * immediately (i=NULL, eol=1), the standard PulseAudio
         * client-side convention for "no more results". */
        cb(c, NULL, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_context_set_sink_input_volume(pa_context *c, uint32_t idx, const pa_cvolume *volume, pa_context_success_cb_t cb, void *userdata) {
    (void)idx;
    (void)volume;
    if (cb) {
        cb(c, 1, userdata);
    }
    return _operation_new_done();
}

/* ==================================================================== */
/* pulse/operation.h                                                    */
/* ==================================================================== */

pa_operation_state_t pa_operation_get_state(const pa_operation *o) {
    return o ? o->state : PA_OPERATION_DONE;
}

void pa_operation_unref(pa_operation *o) {
    free(o);
}

/* ==================================================================== */
/* pulse/stream.h                                                       */
/* ==================================================================== */

static pa_stream *_stream_new(pa_context *c, const pa_sample_spec *ss) {
    pa_stream *s = calloc(1, sizeof(*s));
    if (!s) {
        return NULL;
    }
    s->context = c;
    s->state = PA_STREAM_UNCONNECTED;
    if (ss) {
        s->sample_spec = *ss;
    }
    s->index = next_stream_index++;
    return s;
}

pa_stream *pa_stream_new(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map) {
    (void)name;
    (void)map;
    return _stream_new(c, ss);
}

pa_stream *pa_stream_new_with_proplist(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map, pa_proplist *p) {
    (void)name;
    (void)map;
    (void)p;
    return _stream_new(c, ss);
}

void pa_stream_unref(pa_stream *s) {
    free(s);
}

pa_stream_state_t pa_stream_get_state(const pa_stream *s) {
    return s ? s->state : PA_STREAM_UNCONNECTED;
}

void pa_stream_set_state_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    if (!s) {
        return;
    }
    s->state_cb = cb;
    s->state_userdata = userdata;
}

void pa_stream_set_started_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    if (!s) {
        return;
    }
    s->started_cb = cb;
    s->started_userdata = userdata;
}

void pa_stream_set_underflow_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    if (!s) {
        return;
    }
    s->underflow_cb = cb;
    s->underflow_userdata = userdata;
}

int pa_stream_connect_playback(pa_stream *s, const char *dev, const pa_buffer_attr *attr,
                                pa_stream_flags_t flags, const pa_cvolume *volume, pa_stream *sync_stream) {
    (void)dev;
    (void)attr;
    (void)flags;
    (void)volume;
    (void)sync_stream;
    if (!s) {
        return -1;
    }
    _stream_set_state(s, PA_STREAM_READY);
    if (s->started_cb) {
        s->started_cb(s, s->started_userdata);
    }
    return 0;
}

int pa_stream_disconnect(pa_stream *s) {
    if (!s) {
        return -1;
    }
    _stream_set_state(s, PA_STREAM_TERMINATED);
    return 0;
}

uint32_t pa_stream_get_index(const pa_stream *s) {
    return s ? s->index : 0;
}

int pa_stream_is_corked(pa_stream *s) {
    return s ? s->corked : 0;
}

pa_operation *pa_stream_cork(pa_stream *s, int b, pa_stream_success_cb_t cb, void *userdata) {
    if (s) {
        s->corked = b ? 1 : 0;
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_stream_update_timing_info(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    if (s) {
        _stream_refresh_timing(s);
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

const pa_timing_info *pa_stream_get_timing_info(pa_stream *s) {
    if (!s) {
        return NULL;
    }
    _stream_refresh_timing(s);
    return &s->timing;
}

size_t pa_stream_writable_size(const pa_stream *s) {
    (void)s;
    /* Generous, constant "always ready" size -- this stub forwards
     * every write to the output FD synchronously, so Soloist never
     * needs to throttle against a real ring buffer. */
    return 65536;
}

/* The load-bearing function: forward Soloist's already-encoded PCM
 * (S32LE / 44100 Hz / stereo, per spike results) to the resolved
 * output FD (see _pcm_output_fd() / file header). */
int pa_stream_write(pa_stream *s, const void *data, size_t nbytes,
                     pa_free_cb_t free_cb, int64_t offset, pa_seek_mode_t seek) {
    (void)offset;
    (void)seek;
    if (!s || (!data && nbytes > 0)) {
        return -1;
    }

    if (data && nbytes > 0) {
        int fd = _pcm_output_fd();
        const char *p = (const char *)data;
        size_t remaining = nbytes;
        while (fd >= 0 && remaining > 0) {
            ssize_t w = write(fd, p, remaining);
            if (w < 0) {
                if (errno == EINTR) {
                    continue;
                }
                /* Output target gone (e.g. reader closed the pipe) --
                 * drop the remainder rather than block Soloist
                 * forever; playback continuing silently is preferable
                 * to a hung daemon. */
                break;
            }
            p += w;
            remaining -= (size_t)w;
        }
    }

    s->bytes_written += (int64_t)nbytes;

    if (free_cb) {
        free_cb((void *)data);
    }

    return 0;
}

/* ==================================================================== */
/* pulse/proplist.h                                                     */
/* ==================================================================== */

pa_proplist *pa_proplist_new(void) {
    return calloc(1, sizeof(struct pa_proplist));
}

void pa_proplist_free(pa_proplist *p) {
    free(p);
}

int pa_proplist_sets(pa_proplist *p, const char *key, const char *value) {
    (void)p;
    (void)key;
    (void)value;
    return 0; /* success -- nothing in this stub ever reads properties back */
}

/* ==================================================================== */
/* pulse/volume.h                                                       */
/* ==================================================================== */

pa_volume_t pa_cvolume_avg(const pa_cvolume *a) {
    if (!a || a->channels == 0) {
        return 0;
    }
    uint64_t sum = 0;
    unsigned n = a->channels > PA_CHANNELS_MAX ? PA_CHANNELS_MAX : a->channels;
    for (unsigned i = 0; i < n; i++) {
        sum += a->values[i];
    }
    return (pa_volume_t)(sum / n);
}

pa_cvolume *pa_cvolume_set(pa_cvolume *a, unsigned channels, pa_volume_t v) {
    if (!a) {
        return NULL;
    }
    if (channels > PA_CHANNELS_MAX) {
        channels = PA_CHANNELS_MAX;
    }
    a->channels = (uint8_t)channels;
    for (unsigned i = 0; i < channels; i++) {
        a->values[i] = v;
    }
    return a;
}

/* ==================================================================== */
/* pulse/timeval.h + pulse/sample.h                                     */
/* ==================================================================== */

struct timeval *pa_gettimeofday(struct timeval *tv) {
    gettimeofday(tv, NULL);
    return tv;
}

pa_usec_t pa_timeval_diff(const struct timeval *a, const struct timeval *b) {
    if (!a || !b) {
        return 0;
    }
    int64_t secDiff = (int64_t)a->tv_sec - (int64_t)b->tv_sec;
    int64_t usecDiff = (int64_t)a->tv_usec - (int64_t)b->tv_usec;
    int64_t total = secDiff * 1000000 + usecDiff;
    return total < 0 ? 0 : (pa_usec_t)total;
}

size_t pa_usec_to_bytes(pa_usec_t t, const pa_sample_spec *spec) {
    if (!spec || spec->rate == 0) {
        return 0;
    }
    /* Soloist's only output format is S32LE (4 bytes/sample, per
     * spike results) -- hardcoded rather than a full format switch,
     * since this stub only ever needs to support that one format. */
    size_t frameSize = (size_t)spec->channels * 4;
    long double bytes = ((long double)t * spec->rate / 1000000.0L) * frameSize;
    return (size_t)bytes;
}

/* ==================================================================== */
/* pulse/error.h                                                        */
/* ==================================================================== */

const char *pa_strerror(int error) {
    (void)error;
    return "fake-libpulse: no error (stub, D-06)";
}
