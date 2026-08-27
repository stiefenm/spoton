/*
 * fake-libpulse.c -- PulseAudio client API stub for Spotify Soloist
 *
 * SpotOn v4.0 (Soloist Integration), Phase 71 Plan 04, decision D-06.
 * Extended Phase 73 Plan 01, decision D-04 (HTTP streaming mode).
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
 * the PCM buffer Soloist itself already encoded (float32, 44100 Hz,
 * 2 channels -- see ROADMAP.md "Audio Interface" spike result, and
 * Phase 72 UAT correction) and either (Phase 71/72, unchanged when
 * SPOTON_SOLOIST_HTTP_PORT_FILE is unset) forwards those bytes
 * verbatim to an output file descriptor, or (Phase 73, D-04, HTTP
 * mode) converts to S16LE and serves them over a tiny in-process
 * HTTP/1.0 server for the persistent per-player daemon.
 *
 * PCM output target resolution (non-HTTP mode, unchanged from Phase
 * 71/72, resolved once, lazily, on first pa_stream_write() call):
 *   1. SPOTON_SOLOIST_PCM_FD   -- an already-open file descriptor
 *      number (e.g. inherited from the parent process); used as-is.
 *   2. SPOTON_SOLOIST_PCM_PATH -- a filesystem path, opened
 *      O_WRONLY|O_CREAT|O_TRUNC, mode 0600.
 *   3. Fallback: STDOUT_FILENO (1) -- keeps this library self-
 *      contained for standalone/manual testing without either env
 *      var set.
 *
 * HTTP streaming mode (Phase 73, D-04): activated when
 * SPOTON_SOLOIST_HTTP_PORT_FILE is set in the environment BEFORE
 * dlopen() (SoloistDaemon.pm sets it in the spawn env block). When
 * active, pa_stream_write() converts incoming samples to S16LE and
 * pushes them into a bounded ring buffer; a dedicated server thread
 * (started from the constructor, before Soloist calls any pa_*
 * symbol) serves the ring's contents over HTTP GET /stream --
 * semantically identical to the existing librespot /stream relay
 * (librespot-spoton/src/unified.rs, the validated blueprint). This is
 * the ONLY mode used when SPOTON_SOLOIST_HTTP_PORT_FILE is set -- the
 * FD/path resolution above is completely bypassed in that case, and
 * vice versa: when the env var is unset, HTTP mode never activates
 * and all Phase 71/72 behavior is byte-identical (the Phase-72
 * per-track launcher keeps working until 73-04 retires it).
 *
 * This file references no external or private paths -- it ships
 * inside the public SpotOn plugin zip (Bin/<arch>/libpulse.so.0 via
 * the CI cross-compile matrix, D-06).
 */

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

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
/* PCM output target resolution (non-HTTP mode, see file header).     */
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
/* HTTP streaming mode (Phase 73, D-04).                               */
/*                                                                      */
/* Activated only when SPOTON_SOLOIST_HTTP_PORT_FILE is set in the     */
/* environment at dlopen() time (see the constructor at the bottom of  */
/* this section). Everything below is dormant (g_http_mode == 0) and   */
/* zero-cost when unset -- the FD/path path above is used instead.     */
/* ------------------------------------------------------------------ */

/* ~4s of S16LE 44100 Hz stereo (44100 * 2ch * 2bytes = 176400 B/s). */
#define RING_CAPACITY (352800 * 2)

/* Bounded read of the HTTP request head (GET line + headers); any GET
 * is answered -- path checking beyond the fixed /stream endpoint is
 * unnecessary on this single-purpose port. */
#define HTTP_REQUEST_BUF_SIZE 4096
#define HTTP_REQUEST_TIMEOUT_MS 2000

static int g_http_mode = 0; /* 0 = off (Phase 71/72 behavior), 1 = on */
static int g_http_listen_fd = -1;
static pthread_t g_http_thread;

typedef struct {
    unsigned char  *buf;
    size_t          capacity;
    size_t          head;   /* next write offset */
    size_t          tail;   /* next read offset */
    size_t          fill;   /* bytes currently held */
    int             client_connected;
    pthread_mutex_t lock;
    pthread_cond_t  space_avail; /* signaled when bytes are popped */
    pthread_cond_t  data_avail;  /* signaled when bytes are pushed */
} ring_buffer_t;

static ring_buffer_t g_ring;

static void _ring_init(ring_buffer_t *r) {
    r->buf = malloc(RING_CAPACITY);
    r->capacity = RING_CAPACITY;
    r->head = r->tail = r->fill = 0;
    r->client_connected = 0;
    pthread_mutex_init(&r->lock, NULL);
    pthread_cond_init(&r->space_avail, NULL);
    pthread_cond_init(&r->data_avail, NULL);
}

/* Push already-converted S16LE bytes into the ring.
 *
 * Full ring + a client connected: block (cond_wait on space_avail) --
 * this IS the realtime pacing (RESEARCH "Don't Hand-Roll"): Soloist
 * writes as fast as pa_stream_write() accepts it; a bounded ring plus
 * the server thread's real-time drain rate throttles Soloist to
 * approximately real time, exactly like a real PulseAudio sink's
 * tlength buffer attribute.
 *
 * Full ring + no client connected: drop the oldest bytes instead of
 * blocking -- Soloist must never hang just because LMS isn't reading
 * (e.g. Connect session active but the LMS player is paused). */
static void _ring_push(ring_buffer_t *r, const unsigned char *data, size_t n) {
    pthread_mutex_lock(&r->lock);
    while (n > 0) {
        if (r->fill == r->capacity) {
            if (r->client_connected) {
                pthread_cond_wait(&r->space_avail, &r->lock);
                continue;
            }
            size_t drop = n < r->fill ? n : r->fill;
            r->tail = (r->tail + drop) % r->capacity;
            r->fill -= drop;
            continue;
        }

        size_t space = r->capacity - r->fill;
        size_t chunk = n < space ? n : space;
        size_t toEnd = r->capacity - r->head;
        size_t firstPart = chunk < toEnd ? chunk : toEnd;

        memcpy(r->buf + r->head, data, firstPart);
        if (chunk > firstPart) {
            memcpy(r->buf, data + firstPart, chunk - firstPart);
        }

        r->head = (r->head + chunk) % r->capacity;
        r->fill += chunk;
        data += chunk;
        n -= chunk;

        pthread_cond_broadcast(&r->data_avail);
    }
    pthread_mutex_unlock(&r->lock);
}

/* Pop up to maxlen bytes, waiting up to timeout_ms for data to arrive
 * (returns 0 on timeout with the ring still empty). Bounded wait (not
 * an unbounded block) so the HTTP server thread's single loop can
 * still service new accept()s / connection takeover promptly even
 * while a client is attached and the ring is momentarily empty. */
static size_t _ring_pop_timed(ring_buffer_t *r, unsigned char *out, size_t maxlen, int timeout_ms) {
    pthread_mutex_lock(&r->lock);

    if (r->fill == 0) {
        struct timeval now;
        gettimeofday(&now, NULL);
        long usec = now.tv_usec + (long)(timeout_ms % 1000) * 1000;
        struct timespec ts;
        ts.tv_sec  = now.tv_sec + timeout_ms / 1000 + usec / 1000000;
        ts.tv_nsec = (usec % 1000000) * 1000;
        pthread_cond_timedwait(&r->data_avail, &r->lock, &ts);
    }

    size_t chunk = 0;
    if (r->fill > 0) {
        chunk = maxlen < r->fill ? maxlen : r->fill;
        size_t toEnd = r->capacity - r->tail;
        size_t firstPart = chunk < toEnd ? chunk : toEnd;

        memcpy(out, r->buf + r->tail, firstPart);
        if (chunk > firstPart) {
            memcpy(out + firstPart, r->buf, chunk - firstPart);
        }

        r->tail = (r->tail + chunk) % r->capacity;
        r->fill -= chunk;
        pthread_cond_broadcast(&r->space_avail);
    }

    pthread_mutex_unlock(&r->lock);
    return chunk;
}

/* Discards all bytes currently buffered in the ring (D-04, UAT gap 3).
 *
 * Soloist calls pa_stream_flush() when it discards buffered audio on an
 * app-side skip/seek. Before this fix the stub only invoked the success
 * callback -- the ring itself was untouched, so up to RING_CAPACITY
 * (~4.0s) of stale prior-track PCM kept draining out to the player after
 * every skip, AND _stream_refresh_timing()'s read_index (write_index
 * minus ring fill) stayed inflated by that same stale fill, making
 * Soloist's cluster-reported position -- the Spotify app's progress bar
 * -- sit near zero for the first few seconds of the new track while the
 * old audio was still audible. Resetting tail=head and fill=0 here drops
 * the stale bytes instantly and lets read_index catch up to write_index
 * on the very next timing refresh. Broadcasting space_avail wakes any
 * pa_stream_write() blocked in _ring_push() waiting for room (the
 * client-connected backpressure path) so the producer can resume
 * immediately with fresh audio instead of waiting for the (now
 * nonexistent) backlog to drain. */
static void _ring_flush(ring_buffer_t *r) {
    pthread_mutex_lock(&r->lock);
    r->tail = r->head;
    r->fill = 0;
    pthread_cond_broadcast(&r->space_avail);
    pthread_mutex_unlock(&r->lock);
}

/* Converts already-decoded samples to S16LE per the stream's captured
 * sample_spec.format and pushes the result into the ring:
 *   FLOAT32LE -> s16 = (int16_t)lrintf(clamp(f, -1, 1) * 32767.0f)
 *   S32LE     -> arithmetic shift right 16
 *   S16LE     -> memcpy (already the target format)
 * Soloist emits float32 (Phase-72 UAT); the other two branches are
 * cheap defensive completeness, not speculation. Unknown formats are
 * dropped silently rather than risk feeding misinterpreted bytes into
 * the S16LE-only HTTP path. */
static void _convert_and_push(pa_sample_format_t fmt, const void *data, size_t nbytes) {
    if (fmt == PA_SAMPLE_S16LE) {
        _ring_push(&g_ring, (const unsigned char *)data, nbytes);
        return;
    }

    int16_t stackbuf[1024];

    if (fmt == PA_SAMPLE_FLOAT32LE) {
        size_t nsamples = nbytes / sizeof(float);
        const float *src = (const float *)data;
        size_t i = 0;
        while (i < nsamples) {
            size_t batch = nsamples - i;
            if (batch > 1024) batch = 1024;
            for (size_t j = 0; j < batch; j++) {
                float f = src[i + j];
                if (f > 1.0f) f = 1.0f;
                if (f < -1.0f) f = -1.0f;
                stackbuf[j] = (int16_t)lrintf(f * 32767.0f);
            }
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int16_t));
            i += batch;
        }
        return;
    }

    if (fmt == PA_SAMPLE_S32LE) {
        size_t nsamples = nbytes / sizeof(int32_t);
        const int32_t *src = (const int32_t *)data;
        size_t i = 0;
        while (i < nsamples) {
            size_t batch = nsamples - i;
            if (batch > 1024) batch = 1024;
            for (size_t j = 0; j < batch; j++) {
                stackbuf[j] = (int16_t)(src[i + j] >> 16);
            }
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int16_t));
            i += batch;
        }
        return;
    }
}

static void _set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

/* WR-11: a freshly accept()ed connection that hasn't sent its request head
 * yet (portscanner, health checker, misbehaving client) MUST NOT touch the
 * currently active client until the head has actually arrived -- reading
 * it used to be a dedicated blocking-with-poll call (_http_discard_request,
 * up to HTTP_REQUEST_TIMEOUT_MS) invoked AFTER the takeover already
 * happened, which both disconnected the active player and froze this
 * single thread's ring-drain loop for up to 2s per such connection.
 *
 * Replaced by non-blocking, incremental state tracked here and read a
 * little further every _http_thread_fn tick (poll()ed alongside the listen
 * socket and the active client, never blocking) -- the takeover only
 * happens once a complete head has actually been read. */
typedef struct {
    int fd;
    char buf[HTTP_REQUEST_BUF_SIZE];
    size_t len;
    struct timeval started;
} pending_conn_t;

static int _pending_head_complete(const pending_conn_t *p) {
    return strstr(p->buf, "\r\n\r\n") != NULL || strstr(p->buf, "\n\n") != NULL;
}

static long _elapsed_ms(const struct timeval *start) {
    struct timeval now;
    gettimeofday(&now, NULL);
    return (now.tv_sec - start->tv_sec) * 1000
         + (now.tv_usec - start->tv_usec) / 1000;
}

/* Blocking-with-poll write: waits for writability (bounded), then
 * writes; returns -1 on error/hangup/timeout (caller treats this as
 * "client gone" and closes the fd), 0 on full success. fd is expected
 * to be O_NONBLOCK (set at accept time). */
static int _http_write_all(int fd, const unsigned char *data, size_t n) {
    size_t off = 0;
    while (off < n) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        int rc = poll(&pfd, 1, 2000);
        if (rc <= 0) {
            return -1;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            return -1;
        }
        ssize_t w = write(fd, data + off, n - off);
        if (w < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}

/* librespot parity (unified.rs) -- endless stream, no Content-Length.
 * ProtocolHandler already suppresses Range/Enhanced-HTTP for /stream
 * URLs and getFormatForURL maps :port/stream to 'pcm'. */
static const char HTTP_RESPONSE_HEADER[] =
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: audio/L16;rate=44100;channels=2\r\n"
    "Connection: close\r\n"
    "\r\n";

/* Single server thread, multiplexing accept + pending-request-head +
 * streaming with poll() over {listen_fd, pending_fd, client_fd}. WR-11: a
 * newly accepted connection is held in a PENDING slot -- untouched by the
 * active client -- until its request head has actually arrived (or it
 * errors/times out); only THEN does it take over (old fd closed, new fd
 * streamed) -- the same relay-generation takeover semantics as
 * librespot-spoton/src/unified.rs (blueprint, M15), just no longer
 * triggered by the mere act of accept()ing. */
static void *_http_thread_fn(void *arg) {
    (void)arg;
    int client_fd = -1;
    pending_conn_t pending;
    pending.fd = -1;
    pending.len = 0;
    pending.buf[0] = '\0';

    for (;;) {
        struct pollfd fds[2];
        fds[0].fd = g_http_listen_fd;
        fds[0].events = POLLIN;
        int pending_idx = -1;
        if (pending.fd >= 0) {
            pending_idx = 1;
            fds[1].fd = pending.fd;
            fds[1].events = POLLIN;
        }

        int rc = poll(fds, pending_idx >= 0 ? 2 : 1, 50); /* 50ms tick: keep
            servicing the ring even with no incoming/pending activity */

        if (rc > 0 && (fds[0].revents & POLLIN)) {
            int newfd = accept(g_http_listen_fd, NULL, NULL);
            if (newfd >= 0) {
                if (pending.fd >= 0) {
                    /* A newer connection preempts a still-unconfirmed
                     * pending one -- does NOT touch the active client. */
                    close(pending.fd);
                }
                _set_nonblocking(newfd);
                pending.fd = newfd;
                pending.len = 0;
                pending.buf[0] = '\0';    /* clear stale bytes from a prior
                                             pending connection -- without
                                             this, a leftover "\r\n\r\n" tail
                                             in the buffer makes
                                             _pending_head_complete() return
                                             true for a brand-new connection
                                             that hasn't sent a single byte */
                gettimeofday(&pending.started, NULL);
            }
        }

        if (pending.fd >= 0 && pending_idx >= 0 && rc > 0
            && (fds[pending_idx].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)))
        {
            if (fds[pending_idx].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                close(pending.fd);
                pending.fd = -1;
            } else if (pending.len < sizeof(pending.buf) - 1) {
                ssize_t n = read(pending.fd, pending.buf + pending.len,
                                  sizeof(pending.buf) - 1 - pending.len);
                if (n <= 0) {
                    close(pending.fd);
                    pending.fd = -1;
                } else {
                    pending.len += (size_t)n;
                    pending.buf[pending.len] = '\0';
                }
            }
        }

        if (pending.fd >= 0
            && (_pending_head_complete(&pending) || pending.len >= sizeof(pending.buf) - 1))
        {
            /* Full request head arrived (or the bounded buffer filled,
             * matching the old discard function's give-up-parsing
             * behavior) -- NOW take over. */
            if (client_fd >= 0) {
                close(client_fd);
                client_fd = -1;
                pthread_mutex_lock(&g_ring.lock);
                g_ring.client_connected = 0;
                pthread_cond_broadcast(&g_ring.space_avail);
                pthread_mutex_unlock(&g_ring.lock);
            }

            if (_http_write_all(pending.fd, (const unsigned char *)HTTP_RESPONSE_HEADER,
                                 sizeof(HTTP_RESPONSE_HEADER) - 1) == 0) {
                client_fd = pending.fd;
                pthread_mutex_lock(&g_ring.lock);
                g_ring.client_connected = 1;
                pthread_mutex_unlock(&g_ring.lock);
            } else {
                close(pending.fd);
            }
            pending.fd = -1;
            pending.len = 0;
        } else if (pending.fd >= 0 && _elapsed_ms(&pending.started) >= HTTP_REQUEST_TIMEOUT_MS) {
            /* Timed out without a complete head and without an error/EOF --
             * drop silently. The active client (if any) was never touched. */
            close(pending.fd);
            pending.fd = -1;
            pending.len = 0;
        }

        if (client_fd >= 0) {
            unsigned char chunk[16384];
            size_t n = _ring_pop_timed(&g_ring, chunk, sizeof(chunk), 50);
            if (n > 0) {
                if (_http_write_all(client_fd, chunk, n) != 0) {
                    close(client_fd);
                    client_fd = -1;
                    pthread_mutex_lock(&g_ring.lock);
                    g_ring.client_connected = 0;
                    pthread_cond_broadcast(&g_ring.space_avail);
                    pthread_mutex_unlock(&g_ring.lock);
                }
            }
        }
    }

    return NULL; /* unreachable -- daemon lifetime == process lifetime */
}

/* Binds 127.0.0.1... no: binds INADDR_ANY:0 deliberately (see below),
 * announces the resulting port via the file named by
 * SPOTON_SOLOIST_HTTP_PORT_FILE, and starts the server thread.
 *
 * Wildcard bind is deliberate: LMS players stream /stream directly
 * from the LAN -- identical exposure to the existing librespot
 * /stream (RESEARCH Security V4; the Soloist WS control API in
 * contrast stays 127.0.0.1-only, enforced Perl-side in
 * SoloistDaemon.pm/SoloistWS.pm). */
static void _http_start_server(const char *portFilePath) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(0);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return;
    }
    if (listen(fd, 1) < 0) {
        close(fd);
        return;
    }

    struct sockaddr_in bound;
    socklen_t boundlen = sizeof(bound);
    if (getsockname(fd, (struct sockaddr *)&bound, &boundlen) < 0) {
        close(fd);
        return;
    }

    int port = ntohs(bound.sin_port);

    int pf = open(portFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (pf >= 0) {
        char line[32];
        int len = snprintf(line, sizeof(line), "%d\n", port);
        if (len > 0) {
            ssize_t written = write(pf, line, (size_t)len);
            (void)written;
        }
        close(pf);
    }

    g_http_listen_fd = fd;

    if (pthread_create(&g_http_thread, NULL, _http_thread_fn, NULL) != 0) {
        close(fd);
        g_http_listen_fd = -1;
    }
}

/* WR-02: on Linux, write() to a pipe/socket whose read end is closed
 * delivers SIGPIPE, whose default disposition terminates the process
 * -- ignore it so write() returns EPIPE instead (both the non-HTTP FD
 * path and the HTTP server thread's client writes rely on this).
 * Constructor runs once at dlopen() time, before Soloist calls into
 * any pa_* symbol.
 *
 * D-04: also the HTTP-mode activation point. When
 * SPOTON_SOLOIST_HTTP_PORT_FILE is set, the port must be announced
 * (and the server socket listening) before Soloist's own playback
 * setup completes, so SoloistDaemon.pm's async port-file poll
 * succeeds -- start the ring + server thread synchronously here,
 * before returning control to the dynamic loader. */
static int g_debug_trace = 0;
static int g_init_done = 0;

__attribute__((constructor))
static void _fake_libpulse_init(void) {
    signal(SIGPIPE, SIG_IGN);
    g_debug_trace = (getenv("SPOTON_FAKEPULSE_DEBUG") != NULL);

    /* Guard: skip init in the crashpad-handler child process. Soloist
     * forks a crashpad handler that also inherits LD_PRELOAD; if it runs
     * our constructor, it starts a second HTTP server and overwrites the
     * port file with the wrong port. */
    {
        FILE *f = fopen("/proc/self/cmdline", "r");
        if (f) {
            char buf[4096];
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            buf[n] = '\0';
            for (size_t i = 0; i < n; i++) if (buf[i] == '\0') buf[i] = ' ';
            if (strstr(buf, "--type=crashpad")) {
                if (g_debug_trace) fprintf(stderr, "[fakepulse] constructor: skipped (crashpad child)\n");
                return;
            }
        }
    }
    g_init_done = 1;
    if (g_debug_trace) fprintf(stderr, "[fakepulse] constructor: loaded\n");

    const char *portFileEnv = getenv("SPOTON_SOLOIST_HTTP_PORT_FILE");
    if (portFileEnv && *portFileEnv) {
        g_http_mode = 1;
        _ring_init(&g_ring);
        _http_start_server(portFileEnv);
        if (g_debug_trace) fprintf(stderr, "[fakepulse] constructor: HTTP mode, port file=%s, listen_fd=%d\n", portFileEnv, g_http_listen_fd);
    }
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

    if (g_http_mode) {
        /* Position soloist reports tracks what has actually left
         * toward the player (bounded ring depth), limiting
         * position_sync drift (RESEARCH Pitfall 5) -- unlike the
         * non-HTTP path, read_index lags write_index by the ring's
         * current fill. */
        pthread_mutex_lock(&g_ring.lock);
        int64_t fill = (int64_t)g_ring.fill;
        pthread_mutex_unlock(&g_ring.lock);
        s->timing.write_index = s->bytes_written;
        s->timing.read_index = s->bytes_written - fill;
    } else {
        /* No real sink buffer to lag behind -- report the write index
         * as already fully drained (read == write) since bytes handed
         * to pa_stream_write() are forwarded to the output FD
         * synchronously. */
        s->timing.write_index = s->bytes_written;
        s->timing.read_index = s->bytes_written;
    }
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
    if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_context_new(name=%s)\n", name ? name : "(null)");
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
    if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_context_connect(server=%s)\n", server ? server : "(null)");
    (void)server;
    (void)flags;
    (void)api;
    if (!c) {
        return -1;
    }
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
    if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_stream_connect_playback(dev=%s)\n", dev ? dev : "(null)");
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
        if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_stream_cork(%d)\n", b);
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    if (s && g_http_mode) {
        /* HTTP mode only (D-04): the non-HTTP path forwards bytes to the
         * output FD synchronously, so there is nothing buffered to flush
         * there -- keep that path's existing no-op behavior unchanged. */
        _ring_flush(&g_ring);
        _stream_refresh_timing(s);
    }
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
    if (g_http_mode) {
        /* Bounded pacing signal (D-04) -- free ring space, fixes the
         * constant-65536 decode-ahead of RESEARCH Pitfall 5. */
        pthread_mutex_lock(&g_ring.lock);
        size_t freeSpace = g_ring.capacity - g_ring.fill;
        pthread_mutex_unlock(&g_ring.lock);
        return freeSpace;
    }
    /* Generous, constant "always ready" size -- this stub forwards
     * every write to the output FD synchronously, so Soloist never
     * needs to throttle against a real ring buffer. */
    return 65536;
}

/* The load-bearing function: consume Soloist's already-decoded PCM.
 * Non-HTTP mode (unchanged, Phase 71/72): forward verbatim to the
 * resolved output FD. HTTP mode (Phase 73, D-04): convert to S16LE
 * and push into the bounded ring the HTTP server thread drains. */
int pa_stream_write(pa_stream *s, const void *data, size_t nbytes,
                     pa_free_cb_t free_cb, int64_t offset, pa_seek_mode_t seek) {
    static int _write_trace_count = 0;
    if (g_debug_trace && _write_trace_count < 5) {
        fprintf(stderr, "[fakepulse] pa_stream_write(nbytes=%zu)\n", nbytes);
        _write_trace_count++;
        if (_write_trace_count == 5) fprintf(stderr, "[fakepulse] (suppressing further pa_stream_write traces)\n");
    }
    (void)offset;
    (void)seek;
    if (!s || (!data && nbytes > 0)) {
        return -1;
    }

    if (data && nbytes > 0) {
        if (g_http_mode) {
            _convert_and_push(s->sample_spec.format, data, nbytes);
        } else {
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

/* ==================================================================== */
/* Host test harness (Phase 73, D-04) -- built only via                 */
/* `make test` (FAKE_LIBPULSE_TEST), never linked into libpulse.so.0.    */
/* ==================================================================== */
#ifdef FAKE_LIBPULSE_TEST

#include <arpa/inet.h>

static int _test_connect_loopback(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);

    for (int i = 0; i < 100; i++) {
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            return fd;
        }
        usleep(20000);
    }
    close(fd);
    return -1;
}

/* Reads and validates just the HTTP response header (up to the blank
 * line), byte-at-a-time -- extracted out of _test_read_response so the
 * WR-11 regression test below can confirm a connection has been promoted
 * to the active client without also having to know how many body bytes
 * are available to read next (which depends on ring leftovers from
 * whichever test ran previously). Returns 0 on success. */
static int _test_read_header(int fd, int timeout_ms) {
    char hdrbuf[4096];
    size_t hdrlen = 0;
    struct timeval start, now;
    gettimeofday(&start, NULL);

    for (;;) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, 200);
        if (rc > 0 && (pfd.revents & POLLIN)) {
            char c;
            ssize_t n = read(fd, &c, 1);
            if (n <= 0) {
                return -1;
            }
            if (hdrlen < sizeof(hdrbuf) - 1) {
                hdrbuf[hdrlen++] = c;
                hdrbuf[hdrlen] = '\0';
            }
            if (hdrlen >= 4 && memcmp(hdrbuf + hdrlen - 4, "\r\n\r\n", 4) == 0) {
                break;
            }
        }
        gettimeofday(&now, NULL);
        if ((now.tv_sec - start.tv_sec) * 1000 >= timeout_ms) {
            return -1;
        }
    }

    if (strncmp(hdrbuf, "HTTP/1.0 200 OK", 15) != 0) {
        fprintf(stderr, "  bad status line: %.40s\n", hdrbuf);
        return -1;
    }
    if (!strstr(hdrbuf, "audio/L16;rate=44100;channels=2")) {
        fprintf(stderr, "  missing Content-Type header\n");
        return -1;
    }
    return 0;
}

/* Reads and validates the HTTP response header, then reads exactly
 * 'want' bytes of body into out. Returns 0 on success. */
static int _test_read_response(int fd, unsigned char *out, size_t want, int timeout_ms) {
    if (_test_read_header(fd, timeout_ms) != 0) {
        return -1;
    }

    struct timeval start, now;
    size_t got = 0;
    gettimeofday(&start, NULL);
    while (got < want) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, 200);
        if (rc > 0 && (pfd.revents & POLLIN)) {
            ssize_t n = read(fd, out + got, want - got);
            if (n <= 0) {
                return -1;
            }
            got += (size_t)n;
        }
        gettimeofday(&now, NULL);
        if ((now.tv_sec - start.tv_sec) * 1000 >= timeout_ms) {
            return -1;
        }
    }
    return 0;
}

/* Reads exactly 'want' raw bytes on an already-streaming connection (no
 * HTTP header parsing, unlike _test_read_response) -- bounded by
 * timeout_ms. Returns 0 on success, -1 on timeout/EOF/error. */
static int _test_read_bytes(int fd, unsigned char *out, size_t want, int timeout_ms) {
    size_t got = 0;
    struct timeval start, now;
    gettimeofday(&start, NULL);
    while (got < want) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, 200);
        if (rc > 0 && (pfd.revents & POLLIN)) {
            ssize_t n = read(fd, out + got, want - got);
            if (n <= 0) {
                return -1;
            }
            got += (size_t)n;
        }
        gettimeofday(&now, NULL);
        if ((now.tv_sec - start.tv_sec) * 1000 >= timeout_ms) {
            return -1;
        }
    }
    return 0;
}

/* Counts pa_stream_flush success-callback invocations for the flush
 * test below -- reset is not needed since the flush test runs exactly
 * once per test binary invocation. */
static int _test_flush_cb_count = 0;
static void _test_flush_cb(pa_stream *s, int success, void *userdata) {
    (void)s;
    (void)success;
    (void)userdata;
    _test_flush_cb_count++;
}

int main(void) {
    int failures = 0;

    char portFilePath[256];
    snprintf(portFilePath, sizeof(portFilePath), "/tmp/fake-libpulse-test-port-%d", (int)getpid());
    unlink(portFilePath);
    setenv("SPOTON_SOLOIST_HTTP_PORT_FILE", portFilePath, 1);

    /* Runs the same constructor path the dynamic loader would run on
     * dlopen() -- this test binary just calls it explicitly instead of
     * relying on __attribute__((constructor)) auto-invocation, so the
     * env var above (set in this same process) is visible to it. */
    _fake_libpulse_init();

    int port = -1;
    for (int i = 0; i < 100 && port < 0; i++) {
        FILE *pf = fopen(portFilePath, "r");
        if (pf) {
            if (fscanf(pf, "%d", &port) != 1) {
                port = -1;
            }
            fclose(pf);
        }
        if (port < 0) {
            usleep(20000);
        }
    }
    if (port <= 0) {
        fprintf(stderr, "FAIL: port file never appeared at %s\n", portFilePath);
        return 1;
    }
    printf("ok: HTTP port announced (%d)\n", port);

    pa_sample_spec ss;
    ss.format = PA_SAMPLE_FLOAT32LE;
    ss.rate = 44100;
    ss.channels = 2;
    pa_stream *s = pa_stream_new(NULL, "test", &ss, NULL);
    if (!s) {
        fprintf(stderr, "FAIL: pa_stream_new returned NULL\n");
        return 1;
    }
    pa_stream_connect_playback(s, NULL, NULL, 0, NULL, NULL);

    int client = _test_connect_loopback(port);
    if (client < 0) {
        fprintf(stderr, "FAIL: could not connect to announced port\n");
        return 1;
    }

    static const char req[] = "GET /stream HTTP/1.0\r\n\r\n";
    if (write(client, req, sizeof(req) - 1) < 0) {
        fprintf(stderr, "FAIL: could not send GET /stream\n");
        return 1;
    }

    /* Known pattern: 1.0, -1.0, 0.5, 2.0 (clamped), -3.0 (clamped), 0.0 */
    float pattern[6] = { 1.0f, -1.0f, 0.5f, 2.0f, -3.0f, 0.0f };
    pa_stream_write(s, pattern, sizeof(pattern), NULL, 0, 0);

    int16_t expected[6] = { 32767, -32767, 16384, 32767, -32767, 0 };
    unsigned char got[12];
    if (_test_read_response(client, got, sizeof(got), 3000) != 0) {
        fprintf(stderr, "FAIL: did not receive expected HTTP response\n");
        failures++;
    } else if (memcmp(got, expected, sizeof(expected)) != 0) {
        int16_t gotVals[6];
        memcpy(gotVals, got, sizeof(gotVals));
        fprintf(stderr, "FAIL: f32->s16 conversion mismatch: got %d %d %d %d %d %d\n",
                gotVals[0], gotVals[1], gotVals[2], gotVals[3], gotVals[4], gotVals[5]);
        failures++;
    } else {
        printf("ok: f32->s16 conversion + clamping (header + body over real /stream)\n");
    }

    /* Flush test (Task 2, 73-06, D-04/UAT gap 3): pa_stream_flush must
     * discard everything currently buffered in the ring and let a fresh
     * write reach the client afterward, with the discarded bytes never
     * appearing on the wire. Reuses the already-connected `client`
     * socket from the conversion check above (past its HTTP header). */
    {
        /* Detach the ring from the drain loop (same direct-struct-access
         * technique as the drop-oldest / writable_size tests below) so
         * the second pattern accumulates in the ring instead of being
         * drained straight out to `client` before we can observe/flush
         * it -- the socket itself stays open and is read again below. */
        pthread_mutex_lock(&g_ring.lock);
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);

        size_t before = pa_stream_writable_size(s);

        /* Second, recognizable pattern -- must be discarded by the
         * flush below and never reach the client. */
        float flushed_pattern[4] = { 0.25f, -0.25f, 0.75f, -0.75f };
        pa_stream_write(s, flushed_pattern, sizeof(flushed_pattern), NULL, 0, 0);

        size_t after_write = pa_stream_writable_size(s);

        if (before != (size_t)RING_CAPACITY) {
            fprintf(stderr, "FAIL: writable_size before flush-test write != capacity (before=%zu)\n", before);
            failures++;
        } else if (!(after_write < before)) {
            fprintf(stderr, "FAIL: writable_size did not shrink before flush (before=%zu after=%zu)\n",
                    before, after_write);
            failures++;
        }

        pa_operation *flush_op = pa_stream_flush(s, _test_flush_cb, NULL);
        if (flush_op) {
            pa_operation_unref(flush_op);
        }

        size_t after_flush = pa_stream_writable_size(s);

        if (after_flush != (size_t)RING_CAPACITY) {
            fprintf(stderr, "FAIL: writable_size not back to full capacity after flush (after_flush=%zu, capacity=%d)\n",
                    after_flush, RING_CAPACITY);
            failures++;
        }

        if (_test_flush_cb_count != 1) {
            fprintf(stderr, "FAIL: flush success callback fired %d time(s) (expected 1)\n", _test_flush_cb_count);
            failures++;
        }

        /* Re-attach the client and confirm a third, fresh pattern is
         * what actually arrives -- the flushed second pattern must
         * never appear on the wire. */
        pthread_mutex_lock(&g_ring.lock);
        g_ring.client_connected = 1;
        pthread_mutex_unlock(&g_ring.lock);

        float fresh_pattern[4] = { -1.0f, 1.0f, 0.5f, -0.5f };
        int16_t expected_fresh[4] = { -32767, 32767, 16384, -16384 };
        pa_stream_write(s, fresh_pattern, sizeof(fresh_pattern), NULL, 0, 0);

        unsigned char got_fresh[8];
        if (_test_read_bytes(client, got_fresh, sizeof(got_fresh), 3000) != 0) {
            fprintf(stderr, "FAIL: did not receive post-flush pattern over /stream\n");
            failures++;
        } else if (memcmp(got_fresh, expected_fresh, sizeof(expected_fresh)) != 0) {
            int16_t gotVals[4];
            memcpy(gotVals, got_fresh, sizeof(gotVals));
            fprintf(stderr, "FAIL: post-flush bytes do not match the fresh pattern (flushed bytes leaked?): got %d %d %d %d\n",
                    gotVals[0], gotVals[1], gotVals[2], gotVals[3]);
            failures++;
        } else {
            printf("ok: pa_stream_flush discards buffered audio (writable_size restored, flushed pattern never served, callback fired once)\n");
        }
    }

    close(client);

    /* WR-11 regression: an idle connection that is accepted but never
     * sends a request head must not disconnect the active client, and the
     * active client must keep receiving new PCM data promptly (not stall
     * for up to HTTP_REQUEST_TIMEOUT_MS -- the exact portscanner/health-
     * checker scenario this fix addresses). */
    {
        int active = _test_connect_loopback(port);
        if (active < 0) {
            fprintf(stderr, "FAIL: could not connect active client for WR-11 test\n");
            failures++;
        } else {
            static const char req2[] = "GET /stream HTTP/1.0\r\n\r\n";
            if (write(active, req2, sizeof(req2) - 1) < 0) {
                fprintf(stderr, "FAIL: could not send GET /stream for WR-11 test\n");
                failures++;
            }

            if (_test_read_header(active, 3000) != 0) {
                fprintf(stderr, "FAIL: did not receive response header for WR-11 test\n");
                failures++;
            }

            /* Accept a second connection that sends NOTHING. */
            int idle = _test_connect_loopback(port);
            if (idle < 0) {
                fprintf(stderr, "FAIL: could not open idle connection for WR-11 test\n");
                failures++;
            } else {
                usleep(100000); /* let the server thread accept() it into
                                    the pending slot */

                float sample[2] = { 0.5f, -0.5f };
                struct timeval t0, t1;
                gettimeofday(&t0, NULL);
                pa_stream_write(s, sample, sizeof(sample), NULL, 0, 0);

                unsigned char body[4];
                int ok = (_test_read_bytes(active, body, sizeof(body), 500) == 0);
                gettimeofday(&t1, NULL);
                long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;

                if (!ok) {
                    fprintf(stderr, "FAIL: active client did not receive new PCM data "
                                    "while an idle connection was pending (WR-11)\n");
                    failures++;
                } else if (ms > 500) {
                    fprintf(stderr, "FAIL: active client stalled %ldms with an idle "
                                    "connection pending (WR-11)\n", ms);
                    failures++;
                } else {
                    printf("ok: idle pending connection does not disconnect or stall the active client (WR-11, %ldms)\n", ms);
                }

                close(idle);
            }

            close(active);

            /* The server thread only notices a client's close() by trying
             * to WRITE to it and failing -- and on loopback that failure
             * doesn't always surface on the very first post-close write
             * (the kernel can accept one or two more writes into its send
             * buffer before an RST comes back), so a single fixed sleep is
             * not reliable here. Keep nudging it with tiny flush writes and
             * polling client_connected (reset to 0 exactly when the
             * background thread detects the failure) until it actually
             * goes false, bounded so a genuine regression fails loudly
             * instead of hanging. Needed so the drop-oldest test below
             * starts from a clean "no client" state instead of racing a
             * delayed write-failure against its own bulk push. */
            {
                int stillConnected = 1;
                for (int i = 0; i < 50 && stillConnected; i++) {
                    float flush[2] = { 0.0f, 0.0f };
                    pa_stream_write(s, flush, sizeof(flush), NULL, 0, 0);
                    usleep(20000);
                    pthread_mutex_lock(&g_ring.lock);
                    stillConnected = g_ring.client_connected;
                    pthread_mutex_unlock(&g_ring.lock);
                }
                if (stillConnected) {
                    fprintf(stderr, "FAIL: server thread never noticed the WR-11 test's "
                                    "client close (client_connected still true)\n");
                    failures++;
                }
            }
        }
    }

    /* Drop-oldest test: force client_connected=0 and an empty ring
     * directly (same translation unit, direct struct access), then
     * push far more than RING_CAPACITY worth of samples and confirm
     * the call returns promptly (no producer block) with the ring
     * left completely (but only) full -- oldest bytes were dropped,
     * never blocked on. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);

        size_t nfloats = (RING_CAPACITY / sizeof(int16_t)) + 1000;
        float *big = malloc(nfloats * sizeof(float));
        if (!big) {
            fprintf(stderr, "FAIL: malloc for drop-oldest test\n");
            failures++;
        } else {
            for (size_t i = 0; i < nfloats; i++) {
                big[i] = 0.25f;
            }

            struct timeval t0, t1;
            gettimeofday(&t0, NULL);
            pa_stream_write(s, big, nfloats * sizeof(float), NULL, 0, 0);
            gettimeofday(&t1, NULL);
            free(big);

            long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;

            pthread_mutex_lock(&g_ring.lock);
            size_t fillAfter = g_ring.fill;
            pthread_mutex_unlock(&g_ring.lock);

            if (ms > 5000) {
                fprintf(stderr, "FAIL: pa_stream_write blocked for %ldms with no client connected\n", ms);
                failures++;
            } else if (fillAfter != RING_CAPACITY) {
                fprintf(stderr, "FAIL: ring not full after over-capacity write (fill=%zu, capacity=%d)\n",
                        fillAfter, RING_CAPACITY);
                failures++;
            } else {
                printf("ok: drop-oldest with no client connected (took %ldms, ring full=%zu)\n", ms, fillAfter);
            }
        }
    }

    /* writable_size shrinks as the ring fills. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);

        size_t before = pa_stream_writable_size(s);

        float chunk[1000];
        for (int i = 0; i < 1000; i++) {
            chunk[i] = 0.1f;
        }
        pa_stream_write(s, chunk, sizeof(chunk), NULL, 0, 0);

        size_t after = pa_stream_writable_size(s);

        if (before != (size_t)RING_CAPACITY) {
            fprintf(stderr, "FAIL: writable_size before write != capacity (before=%zu)\n", before);
            failures++;
        } else if (!(after < before)) {
            fprintf(stderr, "FAIL: writable_size did not shrink (before=%zu after=%zu)\n", before, after);
            failures++;
        } else {
            printf("ok: writable_size shrinks as the ring fills (before=%zu after=%zu)\n", before, after);
        }
    }

    unlink(portFilePath);

    if (failures) {
        fprintf(stderr, "%d test(s) FAILED\n", failures);
        return 1;
    }
    printf("All fake-libpulse HTTP mode tests passed\n");
    return 0;
}

#endif /* FAKE_LIBPULSE_TEST */
