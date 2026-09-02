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
 * mode) converts to S32LE and serves them over a tiny in-process
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
 * active, pa_stream_write() converts incoming samples to S32LE and
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
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
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
typedef struct pa_mainloop_api pa_mainloop_api;
typedef struct pa_spawn_api pa_spawn_api;
typedef struct pa_sink_input_info pa_sink_input_info;

/* [pulse/def.h] -- DIAG (fakepulse-timing-buffer): unlike the truly
 * opaque types above, this one is now given its REAL, ABI-stable public
 * layout (verbatim from upstream pulse/def.h) so this stub can read the
 * values Soloist actually requests. Soloist constructs this on the stack
 * (compiled against the real pulse headers, same rationale as
 * pa_timing_info above) and passes it into pa_stream_connect_playback();
 * this stub previously left it completely opaque/untraced. Read-only --
 * this stub never writes through this pointer, only logs its fields at
 * SPOTON_FAKEPULSE_TRACE>=2 (see pa_stream_connect_playback), so getting
 * this layout wrong would show garbage in the trace but cannot corrupt
 * anything or change playback behavior. */
typedef struct pa_buffer_attr {
    uint32_t maxlength;
    uint32_t tlength;
    uint32_t prebuf;
    uint32_t minreq;
    uint32_t fragsize;
} pa_buffer_attr;

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
    struct timeval          connect_time; /* set in pa_stream_connect_playback(),
                                              used for timing.since_underrun (DIAG,
                                              fakepulse-timing-buffer) */
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

/* Output side (ring) is always S32LE 44100 Hz stereo -- Phase 76 D-04:
 * upgraded from S16LE so Soloist's float32 samples keep their full
 * >=24-bit precision through the /stream -> transcode chain
 * (44100 Hz * 2 ch * 4 bytes = 352800 B/s). */
#define RING_BYTES_PER_SEC (44100 * 4 * 2)

/* ~20s of ring capacity. Same duration as the S16 era (352800 * 10
 * bytes = 20s at 2 bytes/sample); the byte count doubles to ~7 MB at
 * 4 bytes/sample -- fixed-size, bounded, negligible on all target
 * platforms (76-RESEARCH Pitfall 3). Gives Soloist's worker thread
 * room to write into before the drop-oldest path in _ring_push kicks
 * in, now that pa_stream_write() never blocks (see _ring_push). */
#define RING_CAPACITY (RING_BYTES_PER_SEC * 20)

/* Bounded read of the HTTP request head (GET line + headers); any GET
 * is answered -- path checking beyond the fixed /stream endpoint is
 * unnecessary on this single-purpose port. */
#define HTTP_REQUEST_BUF_SIZE 4096
#define HTTP_REQUEST_TIMEOUT_MS 2000

static int g_http_mode = 0; /* 0 = off (Phase 71/72 behavior), 1 = on */
static int g_http_listen_fd = -1;
static pthread_t g_http_thread;

/* Forward declaration: the real definition (with the TRACE-level doc
 * comment explaining its 0/1/2 semantics) lives further down, right before
 * _fake_libpulse_init -- but _http_thread_fn (defined below, ahead of that
 * point in file order) needs it for the flush-disconnect debug line. */
static int g_debug_trace;

/* Forward declaration (real definition next to g_debug_trace's, below):
 * 76-07 reconnect-gap instrumentation needs wall-clock ms timestamps on
 * the client attach/close/first-drain trace lines emitted from
 * _http_thread_fn, which precedes _trace_ts in file order. */
static void _trace_ts(char *buf, size_t buflen);

/* 76-07 (WINDOWS #5, D-12): set alongside g_flush_disconnect's consumption
 * so the drain loop can stamp the FIRST successful ring pop after a
 * flush-disconnect (timeline point t4) -- same single-writer (HTTP thread)
 * discipline as g_flush_disconnect's consumption side; only ever touched
 * from _http_thread_fn. */
static int g_awaiting_first_drain = 0;

/* 260827-of9 (~30s Connect-skip audio delay): set by pa_stream_flush() when
 * Soloist discards buffered audio on an app-side skip, consumed by
 * _http_thread_fn's poll loop (never touched directly from pa_stream_flush's
 * caller thread -- the HTTP thread already polls every 50ms, so reacting via
 * this flag keeps a single writer/single reader without a lock, and bounds
 * reaction latency to <50ms). Combined with the existing _ring_flush, this
 * makes LMS's persistent /stream connection drop and reconnect fresh instead
 * of continuing to serve the ring's (now-empty, but still open) connection --
 * squeezelite would otherwise keep the stale connection open with nothing
 * arriving until the next chunk, rather than reconnecting immediately.
 * volatile: written by the pa_stream_flush() caller thread (Soloist's own
 * worker thread), read by the separate HTTP server thread. */
static volatile int g_flush_disconnect = 0;

/* Phase 77 Task 2 (D-02/D-03, RESEARCH Pattern 1 "Seek-Armed Flush"):
 * arms the "next flush is a same-track seek/mismatch reposition, NOT a
 * skip" behavior. Incremented by POST /seek-arm (one arm per expected
 * daemon flush -- seek per D-02, URI-mismatch play per D-05, both share
 * this one mechanism), decremented by pa_stream_flush() when > 0 (which
 * then skips g_flush_disconnect instead of setting it -- the attached
 * client stays connected and simply waits for post-flush data, same as
 * the existing 50ms drain-loop poll already does on any empty ring).
 * A COUNTER, not a one-shot bool: back-to-back arms landing before the
 * first flush arrives (rapid double-seek) are each honored in turn,
 * rather than the second arm silently overwriting/losing the first.
 * Saturates at 8 -- bounds a LAN-spam or stale-arm pile-up (T-77-03)
 * without needing a real DoS-proof cap (arms are cheap, single-int
 * increments). Also has a recovery path (77-REVIEWS.md HIGH): reset to
 * 0 in the POST /boundary handler, since a track/session boundary is
 * Perl's authoritative transition signal -- any arm still pending there
 * is stale by definition (its flush would have preceded the transition
 * if it was ever coming), and without this reset a leaked arm (daemon
 * ignores the seek; WS drops between arm and command; play-from-stopped
 * never flushes) would hold the drain-loop write gate below shut
 * forever, making even a `stopped` -> POST /boundary EOF unreachable --
 * strictly worse than the pre-Phase-77 disconnect-on-every-flush bug
 * this mechanism fixes. atomic_int (not volatile), matching the CR-1
 * precedent established earlier in this same Wave: this flag is
 * written from both threads (HTTP thread on arm/boundary-reset/init,
 * the flush-caller thread on consume), not just read-one/write-other
 * like g_flush_disconnect. */
static atomic_int g_seek_flush_armed = 0;
#define SEEK_FLUSH_ARMED_MAX 8

/* Phase 77 Spike 2 (Bounded Endpoint Prototype): forward declaration, same
 * reason as g_debug_trace's forward declaration above -- the BOUNDARY()
 * macro (real definition further below, next to the other trace macros)
 * is used inside _http_thread_fn's POST /boundary handling and bounded-
 * serving logic, both of which precede that definition in file order. */
static int g_boundary_spike;

/* Phase 77 Spike 2: moved up from next to the other trace macros (it's
 * needed inside _http_thread_fn, defined below, which precedes that
 * location in file order -- same forward-reference reasoning as
 * g_boundary_spike above). Boundary-relevant events only, low frequency.
 * Activated by SPOTON_BOUNDARY_SPIKE=1 env var. Logs pa_stream lifecycle
 * events (Spike 1) and boundary plant/reach events (Spike 2) with
 * bytes_written/total_pushed/total_popped + ring_fill for correlating
 * with WS track_changed timestamps in server.log. */
#define BOUNDARY(fmt, ...) \
    do { \
        if (g_boundary_spike) { \
            char _ts[32]; \
            _trace_ts(_ts, sizeof(_ts)); \
            fprintf(stderr, "[fakepulse BOUNDARY ts=%s] " fmt "\n", _ts, ##__VA_ARGS__); \
        } \
    } while (0)

/* Phase 77 Spike 2: boundary marker. When >= 0, the HTTP serve loop
 * closes the client connection once total_popped reaches this value.
 * Planted by POST /boundary (the HTTP thread itself, on receiving the
 * control request), consumed by the same thread's serve loop -- single
 * thread reads AND writes this, so no lock is needed for correctness of
 * the plant/consume protocol itself; volatile only guards against the
 * compiler caching the value across the poll()/read() calls in between.
 * -1 = no boundary planted (serve indefinitely, existing behavior). */
static volatile int64_t g_boundary_at_pushed = -1;

typedef struct {
    unsigned char  *buf;
    size_t          capacity;
    size_t          head;   /* next write offset */
    size_t          tail;   /* next read offset */
    size_t          fill;   /* bytes currently held */
    int64_t         total_pushed;  /* cumulative S32LE bytes pushed (monotonic, Phase 77 Spike 2) */
    int64_t         total_popped;  /* cumulative S32LE bytes popped (monotonic, Phase 77 Spike 2) */
    int             client_connected;
    pthread_mutex_t lock;
    pthread_cond_t  data_avail;  /* signaled when bytes are pushed */
    pthread_cond_t  space_avail; /* signaled when bytes are popped (Phase 78: backpressure) */
} ring_buffer_t;

static ring_buffer_t g_ring;

/* Debug session soloist-browse-stutter (2026-08-30): the currently active
 * playback stream, tracked purely so the HTTP drain thread can invoke its
 * underflow_cb on a genuine ring-empty transition -- real PulseAudio fires
 * this when the sink runs dry; this stub previously never did (see the doc
 * comment on pa_stream_set_underflow_callback below, which flagged this as
 * an untested "candidate difference from real PulseAudio, worth ruling
 * in/out"). Live reproduction confirmed Soloist writes an initial burst of
 * audio, the ring drains to empty as the HTTP client reads it in real
 * time, and Soloist's writer thread then permanently stops calling
 * pa_stream_write() -- with no underflow_cb ever firing, it has nothing
 * telling it to resume. Single-writer (Soloist's own thread, via
 * pa_stream_connect_playback/pa_stream_unref) / single-reader (HTTP
 * thread) -- but unlike g_flush_disconnect (a coarse one-shot flag
 * consumed once per cycle), this flag is set/reset from BOTH threads on
 * every push/flush/drain, so plain `volatile int` leaves an ARM weak-
 * memory-ordering window where a reset from one thread and a set from
 * the other could race without a happens-before edge (CR-1, D-01).
 * C11 `atomic_int` closes that window: plain `=` assignment and plain
 * reads on an `_Atomic` int are seq_cst atomic operations, so every
 * existing set/reset/read site below needs no syntax change, only the
 * correct primitive. g_ring_underrun_fired is edge-triggered (reset
 * whenever fresh data lands in the ring, in _ring_push/_ring_flush) so
 * the HTTP thread's 50ms poll loop signals a stall exactly once per
 * genuine empty streak, not on every tick. */
static pa_stream *g_active_stream = NULL;
static atomic_int g_ring_underrun_fired = 0;

static void _ring_init(ring_buffer_t *r) {
    r->buf = malloc(RING_CAPACITY);
    r->capacity = RING_CAPACITY;
    r->head = r->tail = r->fill = 0;
    r->total_pushed = 0;  /* Phase 77 Spike 2: monotonic, never reset by flush */
    r->total_popped = 0;
    r->client_connected = 0;
    pthread_mutex_init(&r->lock, NULL);
    pthread_cond_init(&r->data_avail, NULL);
    pthread_cond_init(&r->space_avail, NULL);
}

/* Push already-converted S32LE bytes into the ring.
 *
 * pa_stream_write() must NEVER block the caller (real PulseAudio never
 * blocks pa_stream_write() -- see file header / RESEARCH "PulseAudio
 * Research Summary"). Soloist's own worker thread does all pa_stream_write
 * calls and only exits (triggering the uncork that enables correct
 * position reporting) once every write call has returned -- a blocking
 * write here would hold that thread hostage for the entire track duration.
 *
 * Full ring: block until the HTTP consumer pops data and signals
 * space_avail (Phase 78 fix).  The original drop-oldest approach
 * caused cyclic audio stutter every ~20s — the daemon decoded faster
 * than the HTTP client drained, overflowing the ring.  Blocking here
 * throttles the daemon to the consumer's actual playback rate, which
 * is what real PulseAudio does via buffer backpressure. */
static void _ring_push(ring_buffer_t *r, const unsigned char *data, size_t n) {
    pthread_mutex_lock(&r->lock);
    while (n > 0) {
        if (r->fill == r->capacity) {
            /* Drop-oldest: discard the oldest bytes to make room.
             * The Phase 78 drain-loop fix ensures the HTTP thread drains
             * fast enough to keep up with real-time, so this path should
             * rarely fire during normal playback. */
            size_t drop = n < r->fill ? n : r->fill;
            r->tail = (r->tail + drop) % r->capacity;
            r->fill -= drop;
            r->total_popped += (int64_t)drop;
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
        r->total_pushed += (int64_t)chunk;  /* Phase 77 Spike 2: monotonic write cursor */
        data += chunk;
        n -= chunk;

        pthread_cond_broadcast(&r->data_avail);
    }
    /* Fresh data landed (soloist-browse-stutter fix): allow a future
     * ring-empty transition to signal underflow_cb again. Cheap,
     * unconditional -- g_ring_underrun_fired only matters for g_ring, the
     * sole real instance of this ring type in this stub. */
    if (r->fill > 0) {
        g_ring_underrun_fired = 0;
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
        r->total_popped += (int64_t)chunk;  /* Phase 77 Spike 2: monotonic read cursor */
        pthread_cond_broadcast(&r->space_avail);  /* Phase 78: wake blocked producer */
    }

    pthread_mutex_unlock(&r->lock);
    return chunk;
}

/* Discards all bytes currently buffered in the ring (D-04, UAT gap 3).
 *
 * Soloist calls pa_stream_flush() when it discards buffered audio on an
 * app-side skip/seek. Before this fix the stub only invoked the success
 * callback -- the ring itself was untouched, so up to RING_CAPACITY
 * (~20s) of stale prior-track PCM kept draining out to the player after
 * every skip, AND _stream_refresh_timing()'s read_index (write_index
 * minus ring fill) stayed inflated by that same stale fill, making
 * Soloist's cluster-reported position -- the Spotify app's progress bar
 * -- sit near zero for the first few seconds of the new track while the
 * old audio was still audible. Resetting tail=head and fill=0 here drops
 * the stale bytes instantly and lets read_index catch up to write_index
 * on the very next timing refresh. (pa_stream_write()/_ring_push() never
 * blocks waiting for room -- see _ring_push -- so there is no longer a
 * producer to wake here.) */
static void _ring_flush(ring_buffer_t *r) {
    pthread_mutex_lock(&r->lock);
    r->tail = r->head;
    /* Phase 77 Spike 2: the discarded `fill` bytes are never popped by a
     * real consumer, but total_popped MUST still advance by that amount --
     * the invariant total_pushed - total_popped == fill has to hold at all
     * times, or a boundary marker planted after ANY later flush would
     * permanently need that many extra (unrelated) bytes popped before it
     * ever triggers, drifting further behind with every subsequent skip
     * over a long session. This is a counter-bookkeeping advance only
     * (never reset backward, and never applied to total_pushed) -- it does
     * not itself touch g_boundary_at_pushed; the caller (pa_stream_flush)
     * invalidates that separately, since a marker planted by a boundary
     * this same flush is discarding must not be treated as reached. */
    r->total_popped += (int64_t)r->fill;
    r->fill = 0;
    pthread_cond_broadcast(&r->space_avail);  /* Phase 78: wake blocked producer after flush */
    pthread_mutex_unlock(&r->lock);
    /* soloist-browse-stutter fix: a flush starts a fresh empty streak for
     * the new track -- allow it to signal underflow_cb again once it
     * genuinely drains, same as any other empty transition. */
    g_ring_underrun_fired = 0;
}

/* Converts already-decoded samples to S32LE per the stream's captured
 * sample_spec.format and pushes the result into the ring (Phase 76
 * D-04 -- the ring's native format is S32LE, preserving Soloist's full
 * float32 precision instead of the destructive S16 down-conversion):
 *   FLOAT32LE -> s32 = (int32_t)lrint(clamp(f, -1, 1) * 2147483647.0)
 *                (promoted to DOUBLE before multiplying: 2147483647 is
 *                not representable as a float -- it rounds up to 2^31,
 *                so lrintf(1.0f * 2147483647.0f) would overflow int32)
 *   S32LE     -> memcpy (already the target format)
 *   S16LE     -> up-conversion: ((int32_t)sample) << 16
 * Soloist emits float32 (Phase-72 UAT); the other two branches are
 * cheap defensive completeness, not speculation. Unknown formats are
 * dropped silently rather than risk feeding misinterpreted bytes into
 * the S32LE-only HTTP path. */
static void _convert_and_push(pa_sample_format_t fmt, const void *data, size_t nbytes) {
    if (fmt == PA_SAMPLE_S32LE) {
        _ring_push(&g_ring, (const unsigned char *)data, nbytes);
        return;
    }

    int32_t stackbuf[1024];

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
                stackbuf[j] = (int32_t)lrint((double)f * 2147483647.0);
            }
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int32_t));
            i += batch;
        }
        return;
    }

    if (fmt == PA_SAMPLE_S16LE) {
        size_t nsamples = nbytes / sizeof(int16_t);
        const int16_t *src = (const int16_t *)data;
        size_t i = 0;
        while (i < nsamples) {
            size_t batch = nsamples - i;
            if (batch > 1024) batch = 1024;
            for (size_t j = 0; j < batch; j++) {
                stackbuf[j] = ((int32_t)src[i + j]) << 16;
            }
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int32_t));
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
 * URLs and getFormatForURL maps :port/stream to 'pcm'.
 *
 * Phase 76 D-04: the payload is raw S32LE PCM, 44100 Hz, 2 channels.
 * There is no registered audio/L32 MIME type; audio/x-pcm maps to 'pcm'
 * in stock LMS types.conf (line 45). This matters on the direct-stream
 * path (WR-01): Squeezebox2::directHeaders -> parseDirectHeaders runs
 * mimeToType on this header, and an unmapped type (e.g.
 * application/octet-stream) falls back to 'mp3' -- misclassifying the
 * stream in status queries/UI and polluting the schema's content type
 * via setContentType. Decode itself is governed by the strm frame /
 * convert rules (custom-types.conf 'soc' + samplesize hints). */
static const char HTTP_RESPONSE_HEADER[] =
    "HTTP/1.0 200 OK\r\n"
    "Content-Type: audio/x-pcm\r\n"
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
        /* 260827-of9: react to a pa_stream_flush()-triggered skip BEFORE
         * poll() -- close the active client so LMS's persistent /stream
         * connection drops and squeezelite reconnects fresh instead of
         * waiting on a connection that will only ever serve the NEW track's
         * bytes with no signal that anything changed. A freshly-accepted
         * pending connection (not yet promoted to client_fd) is untouched --
         * WR-11 takeover semantics still apply to it normally. */
        if (g_flush_disconnect && client_fd >= 0) {
            close(client_fd);
            client_fd = -1;
            pthread_mutex_lock(&g_ring.lock);
            g_ring.client_connected = 0;
            pthread_mutex_unlock(&g_ring.lock);
            g_flush_disconnect = 0;
            g_awaiting_first_drain = 1;   /* 76-07: arm the t4 (first-drain) stamp */
            /* Phase 77 Spike 2: an app-side skip flushes the ring (see
             * pa_stream_flush below), which invalidates any bytes a
             * previously-planted boundary marker was counting toward --
             * drop it so a stale marker can't spuriously close whatever
             * client reconnects next. */
            g_boundary_at_pushed = -1;
            if (g_debug_trace) {
                char _ts[32];
                _trace_ts(_ts, sizeof(_ts));
                fprintf(stderr, "[fakepulse %s] flush-disconnect: closed active HTTP client\n", _ts);
            }
        }

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

        /* Phase 77 Spike 2 (Bounded Endpoint Prototype): POST /boundary is a
         * control request, not a streaming client -- plant the marker and
         * respond WITHOUT running the GET /stream takeover logic below,
         * which would otherwise close the currently-attached streaming
         * client for what is really just an out-of-band signal from
         * SoloistWS.pm on WS track_changed. Checked ahead of the takeover
         * block so it can never touch client_fd. */
        if (pending.fd >= 0 && _pending_head_complete(&pending)
            && strstr(pending.buf, "POST") != NULL && strstr(pending.buf, "/boundary") != NULL)
        {
            pthread_mutex_lock(&g_ring.lock);
            g_boundary_at_pushed = g_ring.total_pushed;
            size_t ring_fill_now = g_ring.fill;
            pthread_mutex_unlock(&g_ring.lock);

            /* Phase 77 Task 2 (77-REVIEWS.md HIGH -- arm-counter recovery
             * lifecycle): a track/session boundary is Perl's authoritative
             * transition signal, so any seek-arm still pending here is
             * stale by definition -- its flush would have preceded this
             * boundary if it was ever coming. Reset unconditionally so a
             * leaked arm (daemon ignored the seek; WS dropped between arm
             * and command; play-from-stopped never flushed) can never
             * wedge the drain-loop write gate shut past this transition.
             * Deliberately NOT also cleared in the g_flush_disconnect
             * consumption block below -- an arm landing near an unarmed
             * disconnect may belong to an imminent armed flush for the
             * NEXT track, and this boundary reset alone already
             * guarantees recovery at every transition. Accepted
             * trade-off: an armed seek racing a natural track boundary
             * can have its arm cleared here, degrading that one flush to
             * the pre-Phase-77 disconnect path -- the safe direction
             * (LMS restarts the stream) versus a permanent wedge. */
            g_seek_flush_armed = 0;

            static const char boundary_resp[] =
                "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _http_write_all(pending.fd, (const unsigned char *)boundary_resp,
                             sizeof(boundary_resp) - 1);
            close(pending.fd);
            pending.fd = -1;
            pending.len = 0;

            BOUNDARY("boundary_planted: total_pushed=%lld ring_fill=%zu seek_arm_reset",
                     (long long)g_boundary_at_pushed, ring_fill_now);

            continue; /* back to the top of the for(;;) -- skip GET /stream takeover */
        }

        /* Phase 77 Task 2 (D-02/D-03, RESEARCH Pattern 1): POST /seek-arm
         * is a sibling control request to POST /boundary above -- same
         * bounded pending.buf/_pending_head_complete() parsing (T-77-02),
         * same "respond and continue before the GET /stream takeover"
         * shape so it can never touch client_fd. Parameterless bare
         * trigger (RESEARCH V5 -- no body/query parsing, no new buffer or
         * unbounded read path). Arms (increments, saturating at
         * SEEK_FLUSH_ARMED_MAX) the "next flush is a same-track
         * seek/mismatch reposition, not a skip" behavior consumed by
         * pa_stream_flush() below. */
        if (pending.fd >= 0 && _pending_head_complete(&pending)
            && strstr(pending.buf, "POST") != NULL && strstr(pending.buf, "/seek-arm") != NULL)
        {
            if (g_seek_flush_armed < SEEK_FLUSH_ARMED_MAX) {
                g_seek_flush_armed++;
            }

            static const char seek_arm_resp[] =
                "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _http_write_all(pending.fd, (const unsigned char *)seek_arm_resp,
                             sizeof(seek_arm_resp) - 1);
            close(pending.fd);
            pending.fd = -1;
            pending.len = 0;

            BOUNDARY("seek_arm: armed=%d", (int)g_seek_flush_armed);

            continue; /* back to the top of the for(;;) -- skip GET /stream takeover */
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
                pthread_mutex_unlock(&g_ring.lock);
                if (g_debug_trace) {
                    char _ts[32];
                    _trace_ts(_ts, sizeof(_ts));
                    fprintf(stderr, "[fakepulse %s] client-close: superseded by new connection (takeover)\n", _ts);
                }
            }

            /* Phase 78 fix: if a flush-disconnect is pending but no active
             * client existed to consume it (the flush targeted an already-
             * disconnected client), clear it now — before the new client is
             * promoted — so the fresh client isn't killed on its first
             * empty-ring pass.  Only when superseding (client_fd was >= 0),
             * the flush-disconnect was already consumed at the loop top. */
            int was_supersede = (client_fd >= 0);

            if (_http_write_all(pending.fd, (const unsigned char *)HTTP_RESPONSE_HEADER,
                                 sizeof(HTTP_RESPONSE_HEADER) - 1) == 0) {
                client_fd = pending.fd;
                pthread_mutex_lock(&g_ring.lock);
                g_ring.client_connected = 1;
                pthread_mutex_unlock(&g_ring.lock);
                if (!was_supersede && g_flush_disconnect) {
                    g_flush_disconnect = 0;
                }
                /* 76-07 (WINDOWS #5): t3 -- a new GET /stream client is
                 * attached and will be served from the next drain pass. */
                if (g_debug_trace) {
                    char _ts[32];
                    _trace_ts(_ts, sizeof(_ts));
                    fprintf(stderr, "[fakepulse %s] client-attach: new /stream client fd=%d\n", _ts, client_fd);
                }
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
            /* Phase 78 fix: drain up to HTTP_DRAIN_BUDGET bytes per tick
             * instead of a single 16384-byte pop.  The old fixed chunk
             * capped throughput at 327,680 B/s (16384/0.05) — below the
             * 352,800 B/s needed for S32LE 44.1kHz stereo.  The budget
             * is derived from the actual byte rate with ~2x headroom. */
#define HTTP_DRAIN_CHUNK   16384
#define HTTP_DRAIN_BUDGET  ((size_t)(RING_BYTES_PER_SEC * 0.050 * 2))  /* ~2x headroom per 50ms tick */
            /* Phase 77 Task 2 (D-02/D-03, RESEARCH Pattern 1 step 4 /
             * Pitfall 3): while a seek-arm is pending, the ring may hold
             * pre-seek bytes that must never cross the socket -- to
             * whatever client is attached, including one that took over
             * mid-armed-window (D-02's locked ProtocolHandler-driven
             * seek-restart opens a fresh connection independently of the
             * WS seek command). Skip popping ENTIRELY for this tick (do
             * NOT pop-and-discard -- if a flush never arrives, per the
             * boundary-reset recovery lifecycle above, the un-popped
             * audio must still be there for whichever client eventually
             * gets served). The outer poll() above already ticks every
             * 50ms regardless, so control requests (including the
             * flush-clearing POST /boundary) stay serviced normally. */
            size_t drained_this_tick = 0;
            while (g_seek_flush_armed <= 0 && drained_this_tick < HTTP_DRAIN_BUDGET) {
            unsigned char chunk[HTTP_DRAIN_CHUNK];
            size_t n = _ring_pop_timed(&g_ring, chunk, sizeof(chunk),
                                       drained_this_tick == 0 ? 50 : 0);
            if (n > 0) {
                /* 76-07 (WINDOWS #5): t4 -- first ring drain reaching a
                 * client after a flush-disconnect closed the previous one.
                 * One line per skip cycle (flag re-armed only by the next
                 * flush-disconnect), so level-1 gating is spam-safe. */
                if (g_awaiting_first_drain) {
                    g_awaiting_first_drain = 0;
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] first-drain: %zu bytes to fd=%d after flush-disconnect\n", _ts, n, client_fd);
                    }
                }
                /* Phase 77 Spike 2 (Bounded Endpoint Prototype): if a
                 * boundary marker is armed, cap how much of THIS popped
                 * chunk actually gets written -- bytes at/after the marker
                 * belong to the next track and must not cross the socket
                 * that's about to be closed as that track's EOF.
                 *
                 * Known prototype limitation: _ring_pop_timed() already
                 * removed the full `n` bytes from the ring before this
                 * check runs, so any bytes beyond the boundary within this
                 * SAME chunk (up to sizeof(chunk)-1 = 16383 bytes, ~46ms of
                 * S32LE 44100Hz stereo audio) are dropped rather than
                 * carried over to the next connection. Acceptable for the
                 * spike (bounded, single-chunk, and the ring's ~20s of
                 * lookahead means the next GET reconnects well before this
                 * matters audibly) -- a production version would need a
                 * small carry-over buffer instead of a hard pop-then-trim. */
                size_t write_n = n;
                int at_boundary = 0;
                int64_t boundary = g_boundary_at_pushed;
                int64_t popped_after = 0;
                if (boundary >= 0) {
                    pthread_mutex_lock(&g_ring.lock);
                    popped_after = g_ring.total_popped;  /* already includes this pop */
                    pthread_mutex_unlock(&g_ring.lock);
                    int64_t popped_before = popped_after - (int64_t)n;

                    if (popped_after >= boundary) {
                        int64_t usable = boundary - popped_before;
                        write_n = (usable > 0) ? (size_t)usable : 0;
                        at_boundary = 1;
                    }
                }

                int write_failed = 0;
                if (write_n > 0 && _http_write_all(client_fd, chunk, write_n) != 0) {
                    write_failed = 1;
                }

                if (write_failed) {
                    close(client_fd);
                    client_fd = -1;
                    pthread_mutex_lock(&g_ring.lock);
                    g_ring.client_connected = 0;
                    pthread_mutex_unlock(&g_ring.lock);
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] client-close: write error/disconnect\n", _ts);
                    }
                } else if (at_boundary) {
                    BOUNDARY("boundary_reached: closing client fd=%d wrote=%zu total_popped=%lld boundary=%lld",
                             client_fd, write_n, (long long)popped_after, (long long)boundary);
                    close(client_fd);
                    client_fd = -1;
                    pthread_mutex_lock(&g_ring.lock);
                    g_ring.client_connected = 0;
                    pthread_mutex_unlock(&g_ring.lock);
                    g_boundary_at_pushed = -1;
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] client-close: bounded EOF at track boundary\n", _ts);
                    }
                }
                drained_this_tick += n;
                if (n == 0 || write_failed || at_boundary || client_fd < 0)
                    break;
            } else {
                break;  /* ring empty on non-blocking pop */
            }
            }  /* end while(drained_this_tick < HTTP_DRAIN_BUDGET) */

            /* soloist-browse-stutter fix: real-PA underflow signal. A
             * client is attached and actively being drained (we just
             * either served n>0 bytes or waited the full 50ms and found
             * the ring empty) -- if the ring is genuinely empty, tell the
             * producer (Soloist) via its registered underflow_cb so it
             * knows to feed more audio. Live reproduction confirmed
             * Soloist's writer thread permanently stops calling
             * pa_stream_write() once the ring drains to empty with no
             * feed-me-more signal ever arriving -- this is that signal.
             * Edge-triggered via g_ring_underrun_fired (reset on any fresh
             * ring_push/ring_flush) so this fires once per genuine empty
             * streak, not every 50ms tick while legitimately idle. */
            if (client_fd >= 0) {
                pthread_mutex_lock(&g_ring.lock);
                int ringEmpty = (g_ring.fill == 0);
                pthread_mutex_unlock(&g_ring.lock);
                if (ringEmpty && !g_ring_underrun_fired
                    && g_active_stream && g_active_stream->underflow_cb)
                {
                    g_ring_underrun_fired = 1;
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] underflow: ring empty, invoking underflow_cb\n", _ts);
                    }
                    /* Match real PA's actual dispatch contract: stream
                     * callbacks are invoked with the threaded-mainloop
                     * lock held. Our mutex is recursive (see
                     * pa_threaded_mainloop_new), so this only blocks if a
                     * DIFFERENT thread (Soloist's own) currently holds it
                     * -- exactly the synchronization we want before
                     * handing control to Soloist's callback from this
                     * foreign HTTP thread. */
                    pa_threaded_mainloop *ml = g_active_stream->context ? g_active_stream->context->mainloop : NULL;
                    if (ml) pthread_mutex_lock(&ml->lock);
                    g_active_stream->underflow_cb(g_active_stream, g_active_stream->underflow_userdata);
                    if (ml) pthread_mutex_unlock(&ml->lock);
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
/* g_debug_trace is a LEVEL, not a bool:
 *   0 = off (default)
 *   1 = legacy SPOTON_FAKEPULSE_DEBUG behavior (unchanged since Phase 73)
 *       -- the handful of entry/exit points already instrumented below,
 *       plus the edge-triggered TIMING trace in _stream_refresh_timing().
 *       Low overhead, safe for routine operation.
 *   2 = SPOTON_FAKEPULSE_TRACE=2 -- comprehensive (DIAG,
 *       fakepulse-timing-buffer): every pa_* function call (name +
 *       parameters), every pa_stream_writable_size() return value,
 *       cork/uncork transitions with a wall-clock timestamp, every
 *       timing-info refresh's actual read_index/write_index/playing, and
 *       every state_cb/started_cb invocation with the state value being
 *       reported. Intentionally high-overhead (matches Soloist's own
 *       800-1300 calls/sec timing-poll rate while it's deciding
 *       readiness) -- opt-in only, for short live-debugging bursts,
 *       never the default.
 *
 * SPOTON_FAKEPULSE_TRACE=<N> sets the level explicitly (takes priority
 * over SPOTON_FAKEPULSE_DEBUG). SPOTON_FAKEPULSE_DEBUG (legacy, still set
 * unconditionally by SoloistDaemon.pm) maps to level 1 when TRACE is
 * unset, so existing behavior/tooling is unaffected. */
static int g_debug_trace = 0;
static int g_boundary_spike = 0;
static int g_init_done = 0;

static void _trace_ts(char *buf, size_t buflen) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    snprintf(buf, buflen, "%02d:%02d:%02d.%03ld",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (long)(tv.tv_usec / 1000));
}

/* DIAG (fakepulse-timing-buffer): every trace line carries the calling
 * OS thread id (Linux TID, via the gettid() syscall -- not the pthread_t
 * handle, which isn't directly comparable to what `strace -f`/`ps -T`
 * report) so a live trace can be directly correlated against a
 * per-thread strace capture: `grep 'tid=1234' <log>` tells you exactly
 * which thread calls pa_stream_write/pa_stream_cork/etc., so
 * `strace -f -p <soloist_pid> -e trace=... 2>&1 | grep '^1234 '`
 * (or `strace -p 1234` directly) isolates that one thread instead of
 * wading through the ~19 Chromium/V8-internal threads' futex/epoll
 * churn (see Evidence in .planning/debug/fakepulse-timing-buffer.md --
 * the untargeted `strace -f` capture from an earlier session was too
 * noisy to isolate the relevant thread without this). */
static long _gettid(void) {
    return syscall(SYS_gettid);
}

#define TRACE2(fmt, ...) \
    do { \
        if (g_debug_trace >= 2) { \
            char _ts[32]; \
            _trace_ts(_ts, sizeof(_ts)); \
            fprintf(stderr, "[fakepulse T2 %s tid=%ld] " fmt "\n", _ts, _gettid(), ##__VA_ARGS__); \
        } \
    } while (0)

/* pa_stream_write throttled summary state (Phase 77 Spike 1) */
static struct timeval g_boundary_last_write_summary;
static int g_boundary_write_summary_set = 0;
static int g_boundary_write_count = 0;
static int64_t g_boundary_write_bytes_since = 0;

static const char *_context_state_name(pa_context_state_t s) {
    switch (s) {
        case PA_CONTEXT_UNCONNECTED:  return "UNCONNECTED";
        case PA_CONTEXT_CONNECTING:   return "CONNECTING";
        case PA_CONTEXT_AUTHORIZING:  return "AUTHORIZING";
        case PA_CONTEXT_SETTING_NAME: return "SETTING_NAME";
        case PA_CONTEXT_READY:        return "READY";
        case PA_CONTEXT_FAILED:       return "FAILED";
        case PA_CONTEXT_TERMINATED:   return "TERMINATED";
        default: return "?";
    }
}

static const char *_stream_state_name(pa_stream_state_t s) {
    switch (s) {
        case PA_STREAM_UNCONNECTED: return "UNCONNECTED";
        case PA_STREAM_CREATING:    return "CREATING";
        case PA_STREAM_READY:       return "READY";
        case PA_STREAM_FAILED:      return "FAILED";
        case PA_STREAM_TERMINATED:  return "TERMINATED";
        default: return "?";
    }
}

/* Symbols Soloist actually references, recovered 2026-08-27 (DIAG,
 * fakepulse-timing-buffer) via
 *   sudo strings <soloist binary> | grep -x 'pa_[a-z0-9_]*' | sort -u
 * against the currently-pinned Soloist build (1.3.7.489, x86_64-linux).
 * Soloist dlsym()s these BY STRING NAME -- it never appears as a normal
 * ELF undefined-dynamic-symbol import, since libpulse is dlopen()ed, not
 * link-time linked (`nm -D` on the Soloist binary shows zero pa_*
 * entries at all; `strings` is the only way to recover this list,
 * matching this file's header-comment original derivation method).
 * Exactly 48 symbols, and this stub implements exactly these same 48 --
 * confirmed by diffing against `nm -D libpulse.so.0`'s exported T symbols
 * this session (see .planning/debug/fakepulse-timing-buffer.md
 * Evidence). Hardcoded here (rather than re-deriving at runtime, which
 * would need root to read the Soloist binary -- the daemon itself runs
 * as squeezeboxserver and may not have +r on its own path in all
 * deployments) so the diff can still be logged at every startup.
 * Regenerate both this list and IMPLEMENTED_PA_SYMBOLS below together if
 * either the pinned Soloist build or this file's implemented function
 * set changes. */
static const char *SOLOIST_REFERENCED_PA_SYMBOLS[] = {
    "pa_context_connect", "pa_context_disconnect", "pa_context_errno",
    "pa_context_get_sink_input_info", "pa_context_get_state", "pa_context_new",
    "pa_context_set_sink_input_volume", "pa_context_set_state_callback",
    "pa_context_set_subscribe_callback", "pa_context_subscribe", "pa_context_unref",
    "pa_cvolume_avg", "pa_cvolume_set", "pa_gettimeofday", "pa_operation_get_state",
    "pa_operation_unref", "pa_proplist_free", "pa_proplist_new", "pa_proplist_sets",
    "pa_stream_connect_playback", "pa_stream_cork", "pa_stream_disconnect",
    "pa_stream_flush", "pa_stream_get_index", "pa_stream_get_state",
    "pa_stream_get_timing_info", "pa_stream_is_corked", "pa_stream_new",
    "pa_stream_new_with_proplist", "pa_stream_set_started_callback",
    "pa_stream_set_state_callback", "pa_stream_set_underflow_callback",
    "pa_stream_unref", "pa_stream_update_timing_info", "pa_stream_writable_size",
    "pa_stream_write", "pa_strerror", "pa_threaded_mainloop_free",
    "pa_threaded_mainloop_get_api", "pa_threaded_mainloop_lock",
    "pa_threaded_mainloop_new", "pa_threaded_mainloop_signal",
    "pa_threaded_mainloop_start", "pa_threaded_mainloop_stop",
    "pa_threaded_mainloop_unlock", "pa_threaded_mainloop_wait",
    "pa_timeval_diff", "pa_usec_to_bytes",
};
#define SOLOIST_REFERENCED_PA_SYMBOLS_COUNT \
    (sizeof(SOLOIST_REFERENCED_PA_SYMBOLS) / sizeof(SOLOIST_REFERENCED_PA_SYMBOLS[0]))

/* This stub's implemented symbols -- kept as a second hardcoded list
 * (rather than parsing our own .so's dynamic symbol table at runtime,
 * which would need the same ELF-walking machinery `nm` uses) so the
 * comparison is a trivial string diff over two small arrays. */
static const char *IMPLEMENTED_PA_SYMBOLS[] = {
    "pa_context_connect", "pa_context_disconnect", "pa_context_errno",
    "pa_context_get_sink_input_info", "pa_context_get_state", "pa_context_new",
    "pa_context_set_sink_input_volume", "pa_context_set_state_callback",
    "pa_context_set_subscribe_callback", "pa_context_subscribe", "pa_context_unref",
    "pa_cvolume_avg", "pa_cvolume_set", "pa_gettimeofday", "pa_operation_get_state",
    "pa_operation_unref", "pa_proplist_free", "pa_proplist_new", "pa_proplist_sets",
    "pa_stream_connect_playback", "pa_stream_cork", "pa_stream_disconnect",
    "pa_stream_flush", "pa_stream_get_index", "pa_stream_get_state",
    "pa_stream_get_timing_info", "pa_stream_is_corked", "pa_stream_new",
    "pa_stream_new_with_proplist", "pa_stream_set_started_callback",
    "pa_stream_set_state_callback", "pa_stream_set_underflow_callback",
    "pa_stream_unref", "pa_stream_update_timing_info", "pa_stream_writable_size",
    "pa_stream_write", "pa_strerror", "pa_threaded_mainloop_free",
    "pa_threaded_mainloop_get_api", "pa_threaded_mainloop_lock",
    "pa_threaded_mainloop_new", "pa_threaded_mainloop_signal",
    "pa_threaded_mainloop_start", "pa_threaded_mainloop_stop",
    "pa_threaded_mainloop_unlock", "pa_threaded_mainloop_wait",
    "pa_timeval_diff", "pa_usec_to_bytes",
};
#define IMPLEMENTED_PA_SYMBOLS_COUNT \
    (sizeof(IMPLEMENTED_PA_SYMBOLS) / sizeof(IMPLEMENTED_PA_SYMBOLS[0]))

static int _symbol_in(const char *needle, const char **list, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (strcmp(needle, list[i]) == 0) return 1;
    }
    return 0;
}

/* DIAG (fakepulse-timing-buffer): "we can't intercept dlsym() failures
 * from inside our own .so" -- but we CAN compare what Soloist is known
 * to reference (recovered via `strings`, see above) against what this
 * stub implements, and log the diff at startup. Logged once, at level>=2,
 * from the constructor. */
static void _log_symbol_surface(void) {
    fprintf(stderr, "[fakepulse T2] symbol surface: %zu referenced by Soloist, %zu implemented by this stub\n",
            SOLOIST_REFERENCED_PA_SYMBOLS_COUNT, IMPLEMENTED_PA_SYMBOLS_COUNT);
    int missing = 0;
    for (size_t i = 0; i < SOLOIST_REFERENCED_PA_SYMBOLS_COUNT; i++) {
        if (!_symbol_in(SOLOIST_REFERENCED_PA_SYMBOLS[i], IMPLEMENTED_PA_SYMBOLS, IMPLEMENTED_PA_SYMBOLS_COUNT)) {
            fprintf(stderr, "[fakepulse T2] MISSING: Soloist references %s but this stub does not implement it\n",
                    SOLOIST_REFERENCED_PA_SYMBOLS[i]);
            missing++;
        }
    }
    int extra = 0;
    for (size_t i = 0; i < IMPLEMENTED_PA_SYMBOLS_COUNT; i++) {
        if (!_symbol_in(IMPLEMENTED_PA_SYMBOLS[i], SOLOIST_REFERENCED_PA_SYMBOLS, SOLOIST_REFERENCED_PA_SYMBOLS_COUNT)) {
            fprintf(stderr, "[fakepulse T2] EXTRA: this stub implements %s but Soloist never references it\n",
                    IMPLEMENTED_PA_SYMBOLS[i]);
            extra++;
        }
    }
    if (!missing && !extra) {
        fprintf(stderr, "[fakepulse T2] symbol surface: exact match, 0 missing, 0 extra "
                        "(re-verified 2026-08-27 against the pinned Soloist build -- rules out "
                        "\"Soloist silently disables position reporting because a pa_* symbol "
                        "failed to resolve\" as a cause of this bug)\n");
    }
}

__attribute__((constructor))
static void _fake_libpulse_init(void) {
    signal(SIGPIPE, SIG_IGN);
    g_flush_disconnect = 0;
    g_boundary_at_pushed = -1;  /* Phase 77 Spike 2: explicit reset, matching g_flush_disconnect */
    g_seek_flush_armed = 0;  /* Phase 77 Task 2: explicit reset, same one-shot-flag lifecycle */

    const char *traceEnv = getenv("SPOTON_FAKEPULSE_TRACE");
    if (traceEnv && *traceEnv) {
        g_debug_trace = atoi(traceEnv);
    } else if (getenv("SPOTON_FAKEPULSE_DEBUG") != NULL) {
        g_debug_trace = 1;
    }

    const char *boundaryEnv = getenv("SPOTON_BOUNDARY_SPIKE");
    if (boundaryEnv && *boundaryEnv && atoi(boundaryEnv) > 0) {
        g_boundary_spike = 1;
    }

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
    if (g_debug_trace) fprintf(stderr, "[fakepulse] constructor: loaded (trace level=%d)\n", g_debug_trace);
    if (g_boundary_spike) fprintf(stderr, "[fakepulse] constructor: BOUNDARY SPIKE mode active\n");
    if (g_debug_trace >= 2) _log_symbol_surface();

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
    TRACE2("_context_set_state(context=%p, state=%s) cb=%p", (void *)c, _context_state_name(s), (void *)c->state_cb);
    if (c->state_cb) {
        TRACE2("invoking context state_cb(context=%p, state=%s)", (void *)c, _context_state_name(s));
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
    TRACE2("_stream_set_state(stream=%p, state=%s) cb=%p", (void *)s, _stream_state_name(st), (void *)s->state_cb);
    if (s->state_cb) {
        TRACE2("invoking stream state_cb(stream=%p, state=%s)", (void *)s, _stream_state_name(st));
        s->state_cb(s, s->state_userdata);
    }
    if (s->context && s->context->mainloop) {
        pthread_cond_broadcast(&s->context->mainloop->cond);
    }
}

/* DIAG (fakepulse-timing-buffer, still open -- see .planning/debug/
 * fakepulse-timing-buffer.md): edge-triggered trace, NOT per-call. Live
 * testing showed Soloist calls update_timing_info/get_timing_info at
 * 800-1300 calls/sec while investigating readiness -- per-call fprintf at
 * that rate is itself a confound (competes for g_ring.lock and CPU with
 * Soloist's own audio thread). Logs only on a corked-state transition, plus
 * at most 1 line/2s while corked, to show a stuck episode's progression
 * without material overhead. Keep until the "stuck corked for up to
 * several minutes after an external Connect transfer/skip command" root
 * cause is resolved (confirmed NOT caused by since_underrun/sink_usec/
 * configured_sink_usec always reading 0 -- see Eliminated in the debug
 * file; still open). */
static int g_timing_last_corked = -1;
static struct timeval g_timing_last_logged;
static int g_timing_last_logged_set = 0;

/* RING_BYTES_PER_SEC (S32LE 44100 Hz stereo, 4 bytes/sample) is defined
 * next to RING_CAPACITY above, which now derives from it (Phase 76
 * D-04). */

static void _stream_refresh_timing(pa_stream *s, const char *caller) {
    struct timeval now;
    gettimeofday(&now, NULL);
    memset(&s->timing, 0, sizeof(s->timing));
    s->timing.timestamp = now;
    s->timing.synchronized_clocks = 1;
    /* EXPERIMENT, TESTED AND REVERTED (fakepulse-timing-buffer, 2026-08-27
     * session): tried `s->timing.playing = 1;` unconditionally (theory:
     * real PA's timing_info.playing reflects server-side sink activity,
     * not the client's own cork flag, so mirroring corked back was a
     * fidelity gap Soloist might gate on). Live-tested: a stuck episode
     * with this forced still lasted 147.9s -- LONGER than this session's
     * un-patched baseline (94.3s) -- REFUTING the hypothesis (see
     * Eliminated in .planning/debug/fakepulse-timing-buffer.md). Reverted
     * rather than kept-as-harmless-fidelity-improvement (unlike the
     * since_underrun/sink_usec change) because forcing playing=1 during a
     * GENUINE user-initiated pause (where corked=1 really does mean
     * "nothing is being consumed") would misreport an actively-idle
     * stream as playing -- a plausible new regression for zero measured
     * benefit. */
    s->timing.playing = s->corked ? 0 : 1;

    if (g_http_mode) {
        /* Ring stores S32LE (4 bytes/sample, Phase 76 D-04);
         * bytes_written counts input-format bytes. Scale fill back to
         * input units so the subtraction is consistent — without this,
         * read_index is too high and Soloist computes zero elapsed
         * time. For FLOAT32LE/S32LE input this is identity (both 4
         * bytes/sample); for S16LE input the ring holds twice the
         * input bytes, so fill scales down by half. */
        int input_bps = 4; /* FLOAT32LE / S32LE */
        if (s->sample_spec.format == PA_SAMPLE_S16LE) input_bps = 2;
        pthread_mutex_lock(&g_ring.lock);
        int64_t fill = (int64_t)g_ring.fill;
        pthread_mutex_unlock(&g_ring.lock);
        int64_t fill_input = fill * input_bps / 4;
        s->timing.write_index = s->bytes_written;
        s->timing.read_index = s->bytes_written - fill_input;

        /* since_underrun/sink_usec/configured_sink_usec were always left at
         * 0 by the memset above (real PulseAudio never reports all three as
         * permanently zero for an actively-writing stream). DIAG hypothesis
         * (fakepulse-timing-buffer): a real client's readiness/position
         * logic may treat since_underrun==0 as "just started or just
         * underran, don't trust this yet" indefinitely when it in fact
         * never changes. Populate all three plausibly: since_underrun grows
         * from stream-connect (never underruns in this stub); sink_usec
         * reflects the ring's actual current backlog (fill, in output-
         * format time); configured_sink_usec reports the ring's total
         * capacity as the configured target latency. Purely informational
         * -- does not change what bytes flow through the ring. */
        pa_usec_t since_connect = (pa_usec_t)((now.tv_sec - s->connect_time.tv_sec) * 1000000
                                 + (now.tv_usec - s->connect_time.tv_usec));
        s->timing.since_underrun = since_connect;
        s->timing.sink_usec = (pa_usec_t)(((int64_t)fill * 1000000) / RING_BYTES_PER_SEC);
        s->timing.configured_sink_usec = (pa_usec_t)(((int64_t)RING_CAPACITY * 1000000) / RING_BYTES_PER_SEC);

        if (g_debug_trace >= 2) {
            /* Comprehensive mode (SPOTON_FAKEPULSE_TRACE=2): every call,
             * unconditionally, no throttling -- this is the exact field the
             * user asked to see per-call ("pa_stream_get_timing_info /
             * update_timing_info with the actual read_index/write_index/
             * playing values returned"). Opt-in only; see g_debug_trace
             * comment at the constructor for the overhead tradeoff. */
            char _ts[32];
            _trace_ts(_ts, sizeof(_ts));
            fprintf(stderr,
                "[fakepulse T2 %s] TIMING caller=%s stream=%p corked=%d playing=%d "
                "bytes_written=%lld fill=%lld fill_input=%lld write_index=%lld "
                "read_index=%lld since_underrun=%llu sink_usec=%llu configured_sink_usec=%llu\n",
                _ts, caller, (void *)s, s->corked, s->timing.playing,
                (long long)s->bytes_written, (long long)fill, (long long)fill_input,
                (long long)s->timing.write_index, (long long)s->timing.read_index,
                (unsigned long long)s->timing.since_underrun,
                (unsigned long long)s->timing.sink_usec,
                (unsigned long long)s->timing.configured_sink_usec);
        } else if (g_debug_trace == 1) {
            /* Legacy level-1 behavior: edge-triggered, NOT per-call (see
             * comment above this function for the rationale). */
            int corked_changed = (s->corked != g_timing_last_corked);
            long since_last_ms = g_timing_last_logged_set
                ? (now.tv_sec - g_timing_last_logged.tv_sec) * 1000
                    + (now.tv_usec - g_timing_last_logged.tv_usec) / 1000
                : 999999;
            if (corked_changed || (s->corked && since_last_ms >= 2000)) {
                fprintf(stderr,
                    "[fakepulse] TIMING caller=%s stream=%p corked=%d playing=%d "
                    "bytes_written=%lld fill=%lld fill_input=%lld write_index=%lld "
                    "read_index=%lld since_underrun=%llu sink_usec=%llu\n",
                    caller, (void *)s, s->corked, s->timing.playing,
                    (long long)s->bytes_written, (long long)fill, (long long)fill_input,
                    (long long)s->timing.write_index, (long long)s->timing.read_index,
                    (unsigned long long)s->timing.since_underrun,
                    (unsigned long long)s->timing.sink_usec);
                g_timing_last_logged = now;
                g_timing_last_logged_set = 1;
                g_timing_last_corked = s->corked;
            }
        }
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
    TRACE2("pa_threaded_mainloop_new() -> %p", (void *)m);
    return m;
}

void pa_threaded_mainloop_free(pa_threaded_mainloop *m) {
    TRACE2("pa_threaded_mainloop_free(mainloop=%p)", (void *)m);
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
    TRACE2("pa_threaded_mainloop_start(mainloop=%p)", (void *)m);
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
    TRACE2("pa_threaded_mainloop_stop(mainloop=%p)", (void *)m);
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
    TRACE2("pa_threaded_mainloop_lock(mainloop=%p)", (void *)m);
    if (m) {
        pthread_mutex_lock(&m->lock);
    }
}

void pa_threaded_mainloop_unlock(pa_threaded_mainloop *m) {
    TRACE2("pa_threaded_mainloop_unlock(mainloop=%p)", (void *)m);
    if (m) {
        pthread_mutex_unlock(&m->lock);
    }
}

void pa_threaded_mainloop_wait(pa_threaded_mainloop *m) {
    TRACE2("pa_threaded_mainloop_wait(mainloop=%p) -- blocking", (void *)m);
    if (m) {
        pthread_cond_wait(&m->cond, &m->lock);
    }
    TRACE2("pa_threaded_mainloop_wait(mainloop=%p) -- woke up", (void *)m);
}

void pa_threaded_mainloop_signal(pa_threaded_mainloop *m, int wait_for_accept) {
    TRACE2("pa_threaded_mainloop_signal(mainloop=%p, wait_for_accept=%d)", (void *)m, wait_for_accept);
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
    TRACE2("pa_threaded_mainloop_get_api(mainloop=%p) -> %p", (void *)m, (void *)m);
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
    TRACE2("pa_context_unref(context=%p)", (void *)c);
    free(c);
}

void pa_context_set_state_callback(pa_context *c, pa_context_notify_cb_t cb, void *userdata) {
    TRACE2("pa_context_set_state_callback(context=%p, cb=%p)", (void *)c, (void *)cb);
    if (!c) {
        return;
    }
    c->state_cb = cb;
    c->state_userdata = userdata;
}

void pa_context_set_subscribe_callback(pa_context *c, pa_context_subscribe_cb_t cb, void *userdata) {
    TRACE2("pa_context_set_subscribe_callback(context=%p, cb=%p)", (void *)c, (void *)cb);
    if (!c) {
        return;
    }
    c->subscribe_cb = cb;
    c->subscribe_userdata = userdata;
}

int pa_context_errno(const pa_context *c) {
    TRACE2("pa_context_errno(context=%p) -> 0", (void *)c);
    (void)c;
    return 0; /* stub never fails */
}

pa_context_state_t pa_context_get_state(const pa_context *c) {
    pa_context_state_t st = c ? c->state : PA_CONTEXT_UNCONNECTED;
    TRACE2("pa_context_get_state(context=%p) -> %s", (const void *)c, _context_state_name(st));
    return st;
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
    TRACE2("pa_context_disconnect(context=%p)", (void *)c);
    _context_set_state(c, PA_CONTEXT_TERMINATED);
}

/* ==================================================================== */
/* pulse/subscribe.h + pulse/introspect.h                               */
/* ==================================================================== */

pa_operation *pa_context_subscribe(pa_context *c, pa_subscription_mask_t m, pa_context_success_cb_t cb, void *userdata) {
    TRACE2("pa_context_subscribe(context=%p, mask=%d, cb=%p)", (void *)c, m, (void *)cb);
    (void)m;
    if (cb) {
        cb(c, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_context_get_sink_input_info(pa_context *c, uint32_t idx, pa_sink_input_info_cb_t cb, void *userdata) {
    TRACE2("pa_context_get_sink_input_info(context=%p, idx=%u, cb=%p) -> eol immediately", (void *)c, idx, (void *)cb);
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
    TRACE2("pa_context_set_sink_input_volume(context=%p, idx=%u, volume=%p, cb=%p)", (void *)c, idx, (const void *)volume, (void *)cb);
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
    pa_operation_state_t st = o ? o->state : PA_OPERATION_DONE;
    TRACE2("pa_operation_get_state(op=%p) -> %d", (const void *)o, st);
    return st;
}

void pa_operation_unref(pa_operation *o) {
    TRACE2("pa_operation_unref(op=%p)", (void *)o);
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
    if (g_debug_trace) {
        fprintf(stderr, "[fakepulse] _stream_new(stream=%p, index=%u, format=%d)\n",
                (void *)s, s->index, ss ? ss->format : -1);
    }
    return s;
}

pa_stream *pa_stream_new(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map) {
    TRACE2("pa_stream_new(context=%p, name=%s, format=%d, rate=%u, channels=%u)",
           (void *)c, name ? name : "(null)",
           ss ? ss->format : -1, ss ? ss->rate : 0, ss ? ss->channels : 0);
    (void)name;
    (void)map;
    pa_stream *s = _stream_new(c, ss);
    BOUNDARY("stream_new: stream=%p index=%u format=%d rate=%u channels=%u",
             (void *)s, s ? s->index : 0, ss ? ss->format : -1,
             ss ? ss->rate : 0, ss ? ss->channels : 0);
    return s;
}

pa_stream *pa_stream_new_with_proplist(pa_context *c, const char *name, const pa_sample_spec *ss, const pa_channel_map *map, pa_proplist *p) {
    TRACE2("pa_stream_new_with_proplist(context=%p, name=%s, format=%d, rate=%u, channels=%u, proplist=%p)",
           (void *)c, name ? name : "(null)",
           ss ? ss->format : -1, ss ? ss->rate : 0, ss ? ss->channels : 0, (void *)p);
    (void)name;
    (void)map;
    (void)p;
    pa_stream *s = _stream_new(c, ss);
    BOUNDARY("stream_new_proplist: stream=%p index=%u format=%d rate=%u channels=%u",
             (void *)s, s ? s->index : 0, ss ? ss->format : -1,
             ss ? ss->rate : 0, ss ? ss->channels : 0);
    return s;
}

void pa_stream_unref(pa_stream *s) {
    TRACE2("pa_stream_unref(stream=%p)", (void *)s);
    BOUNDARY("stream_unref: stream=%p bytes_written=%lld",
             (void *)s, s ? (long long)s->bytes_written : -1LL);
    if (g_active_stream == s) {
        g_active_stream = NULL;
    }
    free(s);
}

pa_stream_state_t pa_stream_get_state(const pa_stream *s) {
    pa_stream_state_t st = s ? s->state : PA_STREAM_UNCONNECTED;
    TRACE2("pa_stream_get_state(stream=%p) -> %s", (const void *)s, _stream_state_name(st));
    return st;
}

void pa_stream_set_state_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    TRACE2("pa_stream_set_state_callback(stream=%p, cb=%p)", (void *)s, (void *)cb);
    if (!s) {
        return;
    }
    s->state_cb = cb;
    s->state_userdata = userdata;
}

void pa_stream_set_started_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    TRACE2("pa_stream_set_started_callback(stream=%p, cb=%p)", (void *)s, (void *)cb);
    if (!s) {
        return;
    }
    s->started_cb = cb;
    s->started_userdata = userdata;
}

void pa_stream_set_underflow_callback(pa_stream *s, pa_stream_notify_cb_t cb, void *userdata) {
    /* soloist-browse-stutter (2026-08-30): previously this stub NEVER
     * invoked underflow_cb -- it was stored here and then dead for the
     * lifetime of the stream (flagged at the time as an untested
     * "candidate difference from real PulseAudio, worth ruling in/out").
     * Live reproduction confirmed the gap: Soloist writes an initial burst
     * of audio, the ring drains to empty as the HTTP client reads it in
     * real time, and Soloist's writer thread then permanently stops
     * calling pa_stream_write() -- with underflow_cb never firing, it has
     * no signal telling it to resume feeding audio. Now invoked by
     * _http_thread_fn (the ring's sole drain point) on a genuine
     * ring-empty edge, matching real PulseAudio's actual sink-underrun
     * signal. */
    TRACE2("pa_stream_set_underflow_callback(stream=%p, cb=%p) -- invoked on genuine ring-empty transitions (soloist-browse-stutter fix)", (void *)s, (void *)cb);
    if (!s) {
        return;
    }
    s->underflow_cb = cb;
    s->underflow_userdata = userdata;
}

int pa_stream_connect_playback(pa_stream *s, const char *dev, const pa_buffer_attr *attr,
                                pa_stream_flags_t flags, const pa_cvolume *volume, pa_stream *sync_stream) {
    if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_stream_connect_playback(stream=%p, dev=%s)\n", (void *)s, dev ? dev : "(null)");
    TRACE2("pa_stream_connect_playback(stream=%p, dev=%s, flags=%d, sync_stream=%p)",
           (void *)s, dev ? dev : "(null)", flags, (void *)sync_stream);
    if (attr) {
        /* DIAG (fakepulse-timing-buffer): previously completely untraced.
         * prebuf in particular is the real-PA "bytes to prebuffer before
         * the SERVER auto-starts rendering" target -- if Soloist's own
         * uncork decision is byte-count-gated against a value it itself
         * chose here, this reveals the exact target. */
        TRACE2("pa_stream_connect_playback: buffer_attr maxlength=%u tlength=%u prebuf=%u minreq=%u fragsize=%u",
               attr->maxlength, attr->tlength, attr->prebuf, attr->minreq, attr->fragsize);
    }
    (void)dev;
    (void)attr;
    (void)flags;
    (void)volume;
    (void)sync_stream;
    if (!s) {
        return -1;
    }
    /* New stream starts at bytes_written=0; flush stale ring data so
     * read_index doesn't go negative from leftover fill. */
    if (g_http_mode) {
        _ring_flush(&g_ring);
        /* Phase 77 Spike 2: a fresh session start invalidates any marker
         * left over from a prior session -- same reasoning as the
         * pa_stream_flush()/g_flush_disconnect sites. */
        g_boundary_at_pushed = -1;
        /* soloist-browse-stutter fix: track this as the stream whose
         * underflow_cb the HTTP drain thread should invoke on a ring-empty
         * edge -- see g_active_stream's doc comment above g_ring. */
        g_active_stream = s;
    }
    gettimeofday(&s->connect_time, NULL);
    BOUNDARY("connect_playback: stream=%p index=%u bytes_written=0 ring_fill=%zu",
             (void *)s, s->index, g_http_mode ? g_ring.fill : (size_t)0);
    _stream_set_state(s, PA_STREAM_READY);
    /* started_cb now fires on the first pa_stream_write() call (see
     * pa_stream_write), not here at connect time -- real PulseAudio's
     * started_cb fires when the sink actually starts consuming data, not
     * when the stream is merely connected (RESEARCH "PulseAudio Research
     * Summary"). Firing it here was premature relative to real PA and
     * (per the debug session) not what Soloist's worker-thread/uncork
     * logic expects. */
    return 0;
}

int pa_stream_disconnect(pa_stream *s) {
    if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_stream_disconnect(stream=%p)\n", (void *)s);
    TRACE2("pa_stream_disconnect(stream=%p)", (void *)s);
    BOUNDARY("stream_disconnect: stream=%p bytes_written=%lld ring_fill=%zu",
             (void *)s, s ? (long long)s->bytes_written : -1LL,
             g_http_mode ? g_ring.fill : (size_t)0);
    if (!s) {
        return -1;
    }
    _stream_set_state(s, PA_STREAM_TERMINATED);
    return 0;
}

uint32_t pa_stream_get_index(const pa_stream *s) {
    uint32_t idx = s ? s->index : 0;
    TRACE2("pa_stream_get_index(stream=%p) -> %u", (const void *)s, idx);
    return idx;
}

int pa_stream_is_corked(pa_stream *s) {
    int corked = s ? s->corked : 0;
    TRACE2("pa_stream_is_corked(stream=%p) -> %d", (void *)s, corked);
    return corked;
}

pa_operation *pa_stream_cork(pa_stream *s, int b, pa_stream_success_cb_t cb, void *userdata) {
    if (s) {
        int before = s->corked;
        s->corked = b ? 1 : 0;
        if (g_debug_trace) fprintf(stderr, "[fakepulse] pa_stream_cork(stream=%p, b=%d)\n", (void *)s, b);
        TRACE2("pa_stream_cork(stream=%p, requested=%d) corked %d -> %d, cb=%p",
               (void *)s, b, before, s->corked, (void *)cb);
        if (before != s->corked) {
            BOUNDARY("cork: stream=%p %d->%d bytes_written=%lld ring_fill=%zu",
                     (void *)s, before, s->corked,
                     (long long)s->bytes_written,
                     g_http_mode ? g_ring.fill : (size_t)0);
        }
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_stream_flush(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    /* 76-07 (WINDOWS #5): t0 of the reconnect timeline -- Soloist discards
     * buffered audio on an app-side skip. Timestamped so the daemon log can
     * be correlated against LMS server.log's [DIAG] lines (t2). */
    if (g_debug_trace) {
        char _ts[32];
        _trace_ts(_ts, sizeof(_ts));
        fprintf(stderr, "[fakepulse %s] pa_stream_flush(stream=%p)\n", _ts, (void *)s);
    }
    TRACE2("pa_stream_flush(stream=%p, cb=%p)", (void *)s, (void *)cb);
    if (s) {
        BOUNDARY("flush: stream=%p bytes_written=%lld ring_fill=%zu corked=%d",
                 (void *)s, (long long)s->bytes_written,
                 g_http_mode ? g_ring.fill : (size_t)0, s->corked);
    }
    if (s && g_http_mode) {
        /* HTTP mode only (D-04): the non-HTTP path forwards bytes to the
         * output FD synchronously, so there is nothing buffered to flush
         * there -- keep that path's existing no-op behavior unchanged. */
        _ring_flush(&g_ring);
        _stream_refresh_timing(s, "flush");
        /* Phase 77 Spike 2: the flush just discarded whatever audio a
         * planted boundary marker was counting toward -- invalidate it
         * here too (belt-and-suspenders alongside the g_flush_disconnect
         * consumption site in _http_thread_fn, which races this call on a
         * different thread). */
        g_boundary_at_pushed = -1;
        /* 260827-of9 / Phase 77 Task 2 (D-02/D-03): if a seek-arm is
         * pending, this flush is a same-track seek/mismatch reposition
         * (D-02 seek, D-05 URI-mismatch play), NOT an app-side skip --
         * consume one arm and do NOT disconnect. The attached client
         * (old or freshly-taken-over, per the drain-loop write gate
         * below) simply waits: the existing 50ms drain-loop poll already
         * retries an empty ring, so post-flush pa_stream_write() calls
         * refill it and the client keeps streaming uninterrupted.
         * Otherwise (unarmed): unchanged skip/mismatch-without-a-prior-
         * arm behavior (D-12) -- signal the HTTP thread to drop the
         * currently connected client so LMS reconnects fresh rather than
         * continuing to hold a connection whose ring was just emptied. */
        if (g_seek_flush_armed > 0) {
            g_seek_flush_armed--;
        } else {
            g_flush_disconnect = 1;
        }
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

pa_operation *pa_stream_update_timing_info(pa_stream *s, pa_stream_success_cb_t cb, void *userdata) {
    TRACE2("pa_stream_update_timing_info(stream=%p, cb=%p)", (void *)s, (void *)cb);
    if (s) {
        _stream_refresh_timing(s, "update_timing_info");
    }
    if (cb) {
        cb(s, 1, userdata);
    }
    return _operation_new_done();
}

const pa_timing_info *pa_stream_get_timing_info(pa_stream *s) {
    TRACE2("pa_stream_get_timing_info(stream=%p)", (void *)s);
    if (!s) {
        return NULL;
    }
    _stream_refresh_timing(s, "get_timing_info");
    return &s->timing;
}

size_t pa_stream_writable_size(const pa_stream *s) {
    (void)s;
    if (g_http_mode) {
        /* Bounded pacing signal (D-04) -- free ring space, fixes the
         * constant-65536 decode-ahead of RESEARCH Pitfall 5. DIAG
         * (fakepulse-timing-buffer): this was completely UNTRACED before
         * -- explicitly the top candidate for the uncork readiness gate
         * per the user's hypothesis list, since a real client commonly
         * treats "writable_size >= tlength" (or some fraction of it) as
         * its own "ready to consider itself playing" signal. */
        pthread_mutex_lock(&g_ring.lock);
        size_t freeSpace = g_ring.capacity - g_ring.fill;
        size_t fillNow = g_ring.fill;
        pthread_mutex_unlock(&g_ring.lock);
        TRACE2("pa_stream_writable_size(stream=%p) -> %zu (ring fill=%zu / capacity=%d)",
               (const void *)s, freeSpace, fillNow, RING_CAPACITY);
        return freeSpace;
    }
    /* Generous, constant "always ready" size -- this stub forwards
     * every write to the output FD synchronously, so Soloist never
     * needs to throttle against a real ring buffer. */
    TRACE2("pa_stream_writable_size(stream=%p) -> 65536 (non-HTTP mode, constant)", (const void *)s);
    return 65536;
}

/* The load-bearing function: consume Soloist's already-decoded PCM.
 * Non-HTTP mode (unchanged, Phase 71/72): forward verbatim to the
 * resolved output FD. HTTP mode (Phase 73 D-04, S32LE since Phase 76
 * D-04): convert to S32LE and push into the bounded ring the HTTP
 * server thread drains. */
int pa_stream_write(pa_stream *s, const void *data, size_t nbytes,
                     pa_free_cb_t free_cb, int64_t offset, pa_seek_mode_t seek) {
    static int _write_trace_count = 0;
    if (g_debug_trace && _write_trace_count < 5) {
        fprintf(stderr, "[fakepulse] pa_stream_write(nbytes=%zu)\n", nbytes);
        _write_trace_count++;
        if (_write_trace_count == 5) fprintf(stderr, "[fakepulse] (suppressing further pa_stream_write traces)\n");
    }
    /* Comprehensive mode: every call, unconditionally (no 5-call cap --
     * that cap exists only for legacy level-1 log-size hygiene). Includes
     * corked state at time of write -- directly answers "does Soloist
     * keep writing audio while still reporting corked=1". */
    TRACE2("pa_stream_write(stream=%p, nbytes=%zu, offset=%lld, seek=%d, free_cb=%p, corked=%d, bytes_written_before=%lld)",
           (void *)s, nbytes, (long long)offset, seek, (void *)free_cb,
           s ? s->corked : -1, s ? (long long)s->bytes_written : -1LL);
    (void)offset;
    (void)seek;
    if (!s || (!data && nbytes > 0)) {
        return -1;
    }

    /* started_cb fires on the first write, not at connect_playback time
     * (see pa_stream_connect_playback) -- matches real PulseAudio, where
     * started_cb fires when the sink actually starts consuming data.
     * Fire-once: null the pointer immediately after invoking so later
     * writes on this stream don't re-trigger it. */
    if (s->started_cb) {
        TRACE2("pa_stream_write: invoking started_cb(stream=%p) on first write", (void *)s);
        s->started_cb(s, s->started_userdata);
        s->started_cb = NULL;
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

    if (g_boundary_spike) {
        g_boundary_write_count++;
        g_boundary_write_bytes_since += (int64_t)nbytes;
        struct timeval now;
        gettimeofday(&now, NULL);
        int emit = 0;
        if (!g_boundary_write_summary_set) {
            g_boundary_write_summary_set = 1;
            g_boundary_last_write_summary = now;
            emit = 1;
        } else {
            long ms = (now.tv_sec - g_boundary_last_write_summary.tv_sec) * 1000
                    + (now.tv_usec - g_boundary_last_write_summary.tv_usec) / 1000;
            if (ms >= 1000) {
                emit = 1;
                g_boundary_last_write_summary = now;
            }
        }
        if (emit) {
            pthread_mutex_lock(&g_ring.lock);
            size_t fill = g_ring.fill;
            pthread_mutex_unlock(&g_ring.lock);
            char _ts[32];
            _trace_ts(_ts, sizeof(_ts));
            fprintf(stderr, "[fakepulse BOUNDARY ts=%s] write_summary: "
                    "bytes_written=%lld ring_fill=%zu calls=%d bytes_since=%lld corked=%d\n",
                    _ts, (long long)s->bytes_written, fill,
                    g_boundary_write_count, (long long)g_boundary_write_bytes_since,
                    s->corked);
            g_boundary_write_count = 0;
            g_boundary_write_bytes_since = 0;
        }
    }

    if (free_cb) {
        free_cb((void *)data);
    }

    return 0;
}

/* ==================================================================== */
/* pulse/proplist.h                                                     */
/* ==================================================================== */

pa_proplist *pa_proplist_new(void) {
    pa_proplist *p = calloc(1, sizeof(struct pa_proplist));
    TRACE2("pa_proplist_new() -> %p", (void *)p);
    return p;
}

void pa_proplist_free(pa_proplist *p) {
    TRACE2("pa_proplist_free(proplist=%p)", (void *)p);
    free(p);
}

int pa_proplist_sets(pa_proplist *p, const char *key, const char *value) {
    TRACE2("pa_proplist_sets(proplist=%p, key=%s, value=%s)", (void *)p,
           key ? key : "(null)", value ? value : "(null)");
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
        TRACE2("pa_cvolume_avg(cvolume=%p) -> 0 (null/no channels)", (const void *)a);
        return 0;
    }
    uint64_t sum = 0;
    unsigned n = a->channels > PA_CHANNELS_MAX ? PA_CHANNELS_MAX : a->channels;
    for (unsigned i = 0; i < n; i++) {
        sum += a->values[i];
    }
    pa_volume_t avg = (pa_volume_t)(sum / n);
    TRACE2("pa_cvolume_avg(cvolume=%p, channels=%u) -> %u", (const void *)a, a->channels, avg);
    return avg;
}

pa_cvolume *pa_cvolume_set(pa_cvolume *a, unsigned channels, pa_volume_t v) {
    TRACE2("pa_cvolume_set(cvolume=%p, channels=%u, v=%u)", (void *)a, channels, v);
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
    TRACE2("pa_gettimeofday(tv=%p) -> %ld.%06ld", (void *)tv,
           tv ? (long)tv->tv_sec : -1L, tv ? (long)tv->tv_usec : -1L);
    return tv;
}

pa_usec_t pa_timeval_diff(const struct timeval *a, const struct timeval *b) {
    if (!a || !b) {
        return 0;
    }
    int64_t secDiff = (int64_t)a->tv_sec - (int64_t)b->tv_sec;
    int64_t usecDiff = (int64_t)a->tv_usec - (int64_t)b->tv_usec;
    int64_t total = secDiff * 1000000 + usecDiff;
    pa_usec_t result = total < 0 ? 0 : (pa_usec_t)total;
    TRACE2("pa_timeval_diff(a=%p, b=%p) -> %llu usec", (const void *)a, (const void *)b, (unsigned long long)result);
    return result;
}

size_t pa_usec_to_bytes(pa_usec_t t, const pa_sample_spec *spec) {
    if (!spec || spec->rate == 0) {
        TRACE2("pa_usec_to_bytes(t=%llu, spec=%p) -> 0 (null spec or rate=0)", (unsigned long long)t, (const void *)spec);
        return 0;
    }
    /* Soloist's only output format is S32LE (4 bytes/sample, per
     * spike results) -- hardcoded rather than a full format switch,
     * since this stub only ever needs to support that one format. */
    size_t frameSize = (size_t)spec->channels * 4;
    long double bytes = ((long double)t * spec->rate / 1000000.0L) * frameSize;
    size_t result = (size_t)bytes;
    TRACE2("pa_usec_to_bytes(t=%llu, rate=%u, channels=%u) -> %zu", (unsigned long long)t, spec->rate, spec->channels, result);
    return result;
}

/* ==================================================================== */
/* pulse/error.h                                                        */
/* ==================================================================== */

const char *pa_strerror(int error) {
    TRACE2("pa_strerror(error=%d)", error);
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
    if (!strstr(hdrbuf, "audio/x-pcm")) {
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

/* Phase 77 Task 2 test helpers: mirrors the shim's own FLOAT32LE->S32LE
 * conversion (see the PA_SAMPLE_FLOAT32LE branch in pa_stream_write
 * above) so new byte-content assertions can be COMPUTED instead of
 * hand-transcribed -- removes a class of test-authoring transcription
 * error for the seek-armed-flush and leaked-arm host tests below. */
static int32_t _test_f32_to_s32(float f) {
    if (f > 1.0f) f = 1.0f;
    if (f < -1.0f) f = -1.0f;
    return (int32_t)lrint((double)f * 2147483647.0);
}

/* Sends a bare (parameterless) POST control request -- e.g. /seek-arm,
 * /boundary -- over a fresh loopback connection and confirms a 200 OK
 * response. Shared helper for the control-endpoint host tests below
 * (the existing /boundary test above has its own inline copy of this
 * same shape; left untouched, out of this task's scope). Returns 1 on
 * a confirmed 200 OK, 0 otherwise. */
static int _test_post_control(int port, const char *path) {
    int fd = _test_connect_loopback(port);
    if (fd < 0) {
        return 0;
    }
    char req[128];
    int reqLen = snprintf(req, sizeof(req), "POST %s HTTP/1.0\r\nConnection: close\r\n\r\n", path);
    int ok = 0;
    if (reqLen > 0 && write(fd, req, (size_t)reqLen) >= 0) {
        char resp[128];
        size_t rlen = 0;
        struct timeval start, now;
        gettimeofday(&start, NULL);
        while (rlen < sizeof(resp) - 1) {
            struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
            if (poll(&pfd, 1, 200) > 0) {
                ssize_t n = read(fd, resp + rlen, sizeof(resp) - 1 - rlen);
                if (n <= 0) break;
                rlen += (size_t)n;
            }
            gettimeofday(&now, NULL);
            if ((now.tv_sec - start.tv_sec) * 1000 >= 2000) break;
        }
        resp[rlen] = '\0';
        ok = (strncmp(resp, "HTTP/1.0 200 OK", 15) == 0);
    }
    close(fd);
    return ok;
}

/* CR-1 (D-01) hammer test support: counts underflow_cb invocations.
 * Written from the HTTP server thread (the caller of underflow_cb),
 * read from the main test thread's polling loop below -- volatile
 * (rather than a lock) matches this file's existing convention for
 * cross-thread single-writer/single-reader flags (g_flush_disconnect,
 * g_boundary_at_pushed). */
static void _test_underrun_cb(pa_stream *s, void *userdata) {
    (void)s;
    volatile int *counter = (volatile int *)userdata;
    if (counter) {
        (*counter)++;
    }
}

/* CR-1 hammer thread context + body: repeatedly pushes a small chunk
 * then, every 100th iteration, flushes -- both via real pa_stream_write/
 * pa_stream_flush calls on the shared stream handle (not by poking
 * ring globals directly), racing the HTTP drain thread's read/reset of
 * g_ring_underrun_fired on purpose. This IS the CR-1 race: exercising
 * it ~1000 times without a lost/stuck underflow edge is the regression
 * guard. `done` is volatile for the same single-writer/single-reader
 * reason as the underrun counter above -- the main thread's reconnect
 * loop polls it to know when to stop. */
typedef struct {
    pa_stream *stream;
    volatile int done;
} test_hammer_ctx_t;

static void *_test_hammer_thread_fn(void *arg) {
    test_hammer_ctx_t *ctx = (test_hammer_ctx_t *)arg;
    float chunk[4] = { 0.1f, -0.1f, 0.1f, -0.1f };
    for (int i = 0; i < 1000; i++) {
        pa_stream_write(ctx->stream, chunk, sizeof(chunk), NULL, 0, 0);
        if ((i % 100) == 99) {
            pa_operation *op = pa_stream_flush(ctx->stream, NULL, NULL);
            if (op) {
                pa_operation_unref(op);
            }
        }
    }
    ctx->done = 1;
    return NULL;
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

    /* Phase 76 D-04 (S32 ring): 0.5 * 2147483647.0 = 1073741823.5,
     * lrint's round-half-to-even rounds UP to 1073741824. */
    int32_t expected[6] = { 2147483647, -2147483647, 1073741824, 2147483647, -2147483647, 0 };
    unsigned char got[24];
    if (_test_read_response(client, got, sizeof(got), 3000) != 0) {
        fprintf(stderr, "FAIL: did not receive expected HTTP response\n");
        failures++;
    } else if (memcmp(got, expected, sizeof(expected)) != 0) {
        int32_t gotVals[6];
        memcpy(gotVals, got, sizeof(gotVals));
        fprintf(stderr, "FAIL: f32->s32 conversion mismatch: got %d %d %d %d %d %d\n",
                gotVals[0], gotVals[1], gotVals[2], gotVals[3], gotVals[4], gotVals[5]);
        failures++;
    } else {
        printf("ok: f32->s32 conversion + clamping (header + body over real /stream)\n");
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
        int32_t expected_fresh[4] = { -2147483647, 2147483647, 1073741824, -1073741824 };
        pa_stream_write(s, fresh_pattern, sizeof(fresh_pattern), NULL, 0, 0);

        unsigned char got_fresh[16];
        if (_test_read_bytes(client, got_fresh, sizeof(got_fresh), 3000) != 0) {
            fprintf(stderr, "FAIL: did not receive post-flush pattern over /stream\n");
            failures++;
        } else if (memcmp(got_fresh, expected_fresh, sizeof(expected_fresh)) != 0) {
            int32_t gotVals[4];
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

                unsigned char body[8]; /* 2 f32 samples -> 2 S32LE samples */
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

    /* 76-07 (WINDOWS #5, D-12): reconnect-after-flush regression guard.
     * pa_stream_flush() on an app-side skip both empties the ring AND
     * flags the HTTP thread to close the active client (260827-of9). The
     * live-measured ~8s reconnect gap was owned by the LMS-side stream
     * reopen in the pre-76-04 direct-stream configuration, NOT by the
     * shim -- this check pins the shim's half of the contract so it stays
     * that way: the old client is closed within ~1s of the flush, and a
     * new client arriving immediately afterwards is attached and served
     * fresh audio within 500ms of its GET. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);

        int old_fd = _test_connect_loopback(port);
        if (old_fd < 0) {
            fprintf(stderr, "FAIL: could not connect old client for reconnect-after-flush test\n");
            failures++;
        } else {
            static const char req3[] = "GET /stream HTTP/1.0\r\n\r\n";
            if (write(old_fd, req3, sizeof(req3) - 1) < 0) {
                fprintf(stderr, "FAIL: could not send GET for reconnect-after-flush test\n");
                failures++;
            }
            if (_test_read_header(old_fd, 3000) != 0) {
                fprintf(stderr, "FAIL: no response header for reconnect-after-flush old client\n");
                failures++;
            }

            /* Make it an actively-draining client. */
            float pre[2] = { 0.5f, -0.5f };
            pa_stream_write(s, pre, sizeof(pre), NULL, 0, 0);
            unsigned char prebuf[8];
            if (_test_read_bytes(old_fd, prebuf, sizeof(prebuf), 1000) != 0) {
                fprintf(stderr, "FAIL: old client never received pre-flush audio\n");
                failures++;
            }

            /* The skip: flush -> HTTP thread must close the active client. */
            pa_operation *skip_op = pa_stream_flush(s, NULL, NULL);
            if (skip_op) {
                pa_operation_unref(skip_op);
            }

            /* Old socket must reach EOF within ~1s (50ms poll tick + slack). */
            int got_eof = 0;
            for (int i = 0; i < 100 && !got_eof; i++) {
                struct pollfd pfd;
                pfd.fd = old_fd;
                pfd.events = POLLIN;
                int prc = poll(&pfd, 1, 10);
                if (prc > 0) {
                    unsigned char sink[256];
                    ssize_t n = read(old_fd, sink, sizeof(sink));
                    if (n == 0) {
                        got_eof = 1;
                    } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                        got_eof = 1; /* RST also counts as "connection dropped" */
                    }
                }
            }
            close(old_fd);
            if (!got_eof) {
                fprintf(stderr, "FAIL: flush did not disconnect the active client within 1s\n");
                failures++;
            } else {
                /* Immediate reconnect (the LMS/player side reopening the
                 * stream) -- must attach and serve fresh audio promptly. */
                struct timeval rt0, rt1;
                gettimeofday(&rt0, NULL);
                int new_fd = _test_connect_loopback(port);
                if (new_fd < 0) {
                    fprintf(stderr, "FAIL: could not reconnect after flush-disconnect\n");
                    failures++;
                } else {
                    if (write(new_fd, req3, sizeof(req3) - 1) < 0) {
                        fprintf(stderr, "FAIL: could not send GET on reconnected client\n");
                        failures++;
                    }
                    if (_test_read_header(new_fd, 3000) != 0) {
                        fprintf(stderr, "FAIL: no response header on reconnected client\n");
                        failures++;
                    }

                    float fresh[2] = { 0.5f, -0.5f };
                    int32_t expected_reconnect[2] = { 1073741824, -1073741824 };
                    pa_stream_write(s, fresh, sizeof(fresh), NULL, 0, 0);

                    unsigned char got[8];
                    int ok = (_test_read_bytes(new_fd, got, sizeof(got), 500) == 0);
                    gettimeofday(&rt1, NULL);
                    long ms = (rt1.tv_sec - rt0.tv_sec) * 1000 + (rt1.tv_usec - rt0.tv_usec) / 1000;

                    if (!ok) {
                        fprintf(stderr, "FAIL: reconnected client received no audio within 500ms\n");
                        failures++;
                    } else if (memcmp(got, expected_reconnect, sizeof(expected_reconnect)) != 0) {
                        fprintf(stderr, "FAIL: reconnected client received stale/wrong bytes\n");
                        failures++;
                    } else {
                        printf("ok: reconnect after flush-disconnect attaches and drains immediately (%ldms)\n", ms);
                    }
                    close(new_fd);

                    /* Drain the disconnect-notice for the fd we just
                     * closed so the drop-oldest test below starts from a
                     * clean no-client state (same nudge pattern as the
                     * WR-11 cleanup above). */
                    int stillConnected2 = 1;
                    for (int i = 0; i < 50 && stillConnected2; i++) {
                        float flush2[2] = { 0.0f, 0.0f };
                        pa_stream_write(s, flush2, sizeof(flush2), NULL, 0, 0);
                        usleep(20000);
                        pthread_mutex_lock(&g_ring.lock);
                        stillConnected2 = g_ring.client_connected;
                        pthread_mutex_unlock(&g_ring.lock);
                    }
                    if (stillConnected2) {
                        fprintf(stderr, "FAIL: server thread never noticed the reconnect test's client close\n");
                        failures++;
                    }
                }
            }
        }
    }

    /* Phase 77 Spike 2 (Bounded Endpoint Prototype) regression: POST
     * /boundary plants a marker at the ring's CURRENT write position;
     * the serve loop must close the attached client with a real EOF
     * (read() == 0) exactly there -- audio produced strictly BEFORE the
     * marker reaches the client, nothing produced AFTER it does. A fresh
     * connection opened afterward must then stream normally again (the
     * one-shot marker must not linger or corrupt ring state for the next
     * client). */
    {
        pthread_mutex_lock(&g_ring.lock);
        /* Keep the total_pushed - total_popped == fill invariant intact
         * across this raw reset (same reasoning as the _ring_flush fix
         * above) -- otherwise any leftover fill from an earlier test block
         * would leak into this test's boundary math as a phantom gap. */
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int bfd = _test_connect_loopback(port);
        if (bfd < 0) {
            fprintf(stderr, "FAIL: could not connect client for boundary test\n");
            failures++;
        } else if (write(bfd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(bfd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach streaming client for boundary test\n");
            failures++;
            close(bfd);
        } else {
            /* Pre-boundary pattern: must be fully served before the marker. */
            float pre[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
            int32_t expected_pre[4] = { 1073741824, -1073741824, 536870912, -536870912 };
            pa_stream_write(s, pre, sizeof(pre), NULL, 0, 0);

            unsigned char got_pre[16];
            if (_test_read_bytes(bfd, got_pre, sizeof(got_pre), 3000) != 0
                || memcmp(got_pre, expected_pre, sizeof(expected_pre)) != 0) {
                fprintf(stderr, "FAIL: boundary test pre-pattern never arrived or mismatched\n");
                failures++;
            }

            /* Plant the marker over a SEPARATE control connection -- POST
             * /boundary must not disturb the already-attached streaming
             * client (bfd stays open, untouched, until it hits the marker). */
            int ctrl = _test_connect_loopback(port);
            int ctrl_ok = 0;
            if (ctrl >= 0) {
                static const char postReq[] =
                    "POST /boundary HTTP/1.0\r\nConnection: close\r\n\r\n";
                if (write(ctrl, postReq, sizeof(postReq) - 1) >= 0) {
                    char resp[128];
                    size_t rlen = 0;
                    struct timeval cs, cn;
                    gettimeofday(&cs, NULL);
                    while (rlen < sizeof(resp) - 1) {
                        struct pollfd pfd; pfd.fd = ctrl; pfd.events = POLLIN;
                        if (poll(&pfd, 1, 200) > 0) {
                            ssize_t n = read(ctrl, resp + rlen, sizeof(resp) - 1 - rlen);
                            if (n <= 0) break;
                            rlen += (size_t)n;
                        }
                        gettimeofday(&cn, NULL);
                        if ((cn.tv_sec - cs.tv_sec) * 1000 >= 2000) break;
                    }
                    resp[rlen] = '\0';
                    ctrl_ok = (strncmp(resp, "HTTP/1.0 200 OK", 15) == 0);
                }
                close(ctrl);
            }
            if (!ctrl_ok) {
                fprintf(stderr, "FAIL: POST /boundary did not return 200 OK\n");
                failures++;
            }

            /* Next-track precursor: produced AFTER the marker was planted.
             * Known prototype limitation (see the write_n comment in
             * _http_thread_fn): this chunk is popped-and-discarded by the
             * same drain cycle that closes bfd at the boundary, so it does
             * NOT survive for a later client -- verified as "0 bytes leak
             * to bfd" below, not as "arrives intact somewhere else". */
            float afterMarker[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
            pa_stream_write(s, afterMarker, sizeof(afterMarker), NULL, 0, 0);

            int got_eof = 0;
            unsigned char leftover[64];
            size_t leftover_n = 0;
            for (int i = 0; i < 100 && !got_eof; i++) {
                struct pollfd pfd; pfd.fd = bfd; pfd.events = POLLIN;
                if (poll(&pfd, 1, 10) > 0) {
                    ssize_t n = read(bfd, leftover + leftover_n, sizeof(leftover) - leftover_n);
                    if (n == 0) {
                        got_eof = 1;
                    } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                        got_eof = 1;
                    } else if (n > 0) {
                        leftover_n += (size_t)n;
                    }
                }
            }
            close(bfd);

            if (!got_eof) {
                fprintf(stderr, "FAIL: boundary-closed client never reached real EOF within 1s\n");
                failures++;
            } else if (leftover_n != 0) {
                fprintf(stderr, "FAIL: boundary-closed client leaked %zu post-boundary byte(s)\n", leftover_n);
                failures++;
            } else {
                printf("ok: POST /boundary closes the client with a real EOF exactly at the marker (0 bytes leaked)\n");
            }

            /* Fresh connection afterward must stream normally again -- the
             * one-shot marker must not linger past its own consumption. */
            float postClose[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
            int32_t expected_postClose[4] = { 268435456, -268435456, 0, 2147483647 };
            pa_stream_write(s, postClose, sizeof(postClose), NULL, 0, 0);

            int nfd = _test_connect_loopback(port);
            if (nfd < 0) {
                fprintf(stderr, "FAIL: could not open fresh client after boundary EOF\n");
                failures++;
            } else {
                unsigned char got_post[16];
                if (write(nfd, getReq, sizeof(getReq) - 1) < 0
                    || _test_read_header(nfd, 3000) != 0
                    || _test_read_bytes(nfd, got_post, sizeof(got_post), 3000) != 0) {
                    fprintf(stderr, "FAIL: fresh client after boundary EOF did not stream normally\n");
                    failures++;
                } else if (memcmp(got_post, expected_postClose, sizeof(expected_postClose)) != 0) {
                    fprintf(stderr, "FAIL: fresh client after boundary EOF received wrong bytes\n");
                    failures++;
                } else {
                    printf("ok: fresh client after boundary EOF streams normally again\n");
                }
                close(nfd);
            }
        }
    }

    /* CR-1 (D-01): g_ring_underrun_fired concurrency race under
     * hammering push/flush cycles. Attaches a client, spawns a
     * background thread that hammers pa_stream_write/pa_stream_flush
     * ~1000 times (racing the flag's reset side against the HTTP
     * thread's set side), while THIS thread drives the drain path by
     * keeping a client attached throughout (each flush disconnects the
     * currently attached client via the existing g_flush_disconnect
     * path -- today's ordinary flush behavior, not a CR-1 concern --
     * so this thread reconnects whenever that happens). After the
     * hammer thread joins, one final empty->data->empty cycle confirms
     * the underflow edge still fires -- a lost/stuck edge here is
     * exactly the CR-1 failure mode this test guards against. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;

        static volatile int hammer_underrun_count = 0;
        hammer_underrun_count = 0;
        pa_stream_set_underflow_callback(s, _test_underrun_cb, (void *)&hammer_underrun_count);

        static const char hammerGetReq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int hfd = _test_connect_loopback(port);
        int attach_ok = (hfd >= 0
                          && write(hfd, hammerGetReq, sizeof(hammerGetReq) - 1) >= 0
                          && _test_read_header(hfd, 3000) == 0);
        if (!attach_ok) {
            fprintf(stderr, "FAIL: could not attach initial client for CR-1 hammer test\n");
            failures++;
            if (hfd >= 0) close(hfd);
        } else {
            test_hammer_ctx_t ctx;
            ctx.stream = s;
            ctx.done = 0;

            pthread_t hammerThread;
            int spawnRc = pthread_create(&hammerThread, NULL, _test_hammer_thread_fn, &ctx);
            if (spawnRc != 0) {
                fprintf(stderr, "FAIL: could not spawn CR-1 hammer thread (rc=%d)\n", spawnRc);
                failures++;
                close(hfd);
            } else {
                unsigned char discard[4096];
                while (!ctx.done) {
                    if (hfd < 0) {
                        hfd = _test_connect_loopback(port);
                        if (hfd >= 0
                            && (write(hfd, hammerGetReq, sizeof(hammerGetReq) - 1) < 0
                                || _test_read_header(hfd, 500) != 0)) {
                            close(hfd);
                            hfd = -1;
                        }
                    } else {
                        struct pollfd pfd; pfd.fd = hfd; pfd.events = POLLIN;
                        if (poll(&pfd, 1, 20) > 0) {
                            ssize_t n = read(hfd, discard, sizeof(discard));
                            if (n <= 0) {
                                close(hfd);
                                hfd = -1;
                            }
                        }
                    }
                }
                pthread_join(hammerThread, NULL);

                /* Always force a FRESH connection for the final cycle,
                 * even if `hfd` looked still-attached when the discard
                 * loop above exited -- ctx.done can flip true immediately
                 * after the hammer thread's LAST flush call, before the
                 * HTTP thread's next 50ms tick has actually closed that
                 * flush's target client. Reusing a client in that narrow
                 * window is a real (observed) flake: it looks attached
                 * but dies mid-read. A brand-new connect+GET always wins
                 * this race -- the takeover path unconditionally closes
                 * whatever old client-side fd bookkeeping was stale and
                 * clears any leftover flush-disconnect flag before
                 * promoting the new client (see the "Phase 78 fix"
                 * comment on the GET /stream takeover branch above). */
                if (hfd >= 0) {
                    close(hfd);
                    hfd = -1;
                }
                hfd = _test_connect_loopback(port);
                attach_ok = (hfd >= 0
                             && write(hfd, hammerGetReq, sizeof(hammerGetReq) - 1) >= 0
                             && _test_read_header(hfd, 3000) == 0);

                if (!attach_ok) {
                    fprintf(stderr, "FAIL: could not (re)attach client for CR-1 final empty->data->empty cycle\n");
                    failures++;
                } else {
                    int before_count = hammer_underrun_count;

                    float finalChunk[4] = { 0.2f, -0.2f, 0.2f, -0.2f };
                    pa_stream_write(s, finalChunk, sizeof(finalChunk), NULL, 0, 0);

                    unsigned char finalBytes[16];
                    int gotFinal = (_test_read_bytes(hfd, finalBytes, sizeof(finalBytes), 2000) == 0);

                    int fired = 0;
                    for (int i = 0; i < 100 && !fired; i++) {
                        usleep(20000);
                        fired = (hammer_underrun_count > before_count);
                    }

                    if (!gotFinal) {
                        fprintf(stderr, "FAIL: CR-1 hammer test final chunk never reached the client\n");
                        failures++;
                    } else if (!fired) {
                        fprintf(stderr, "FAIL: underflow_cb did not fire after CR-1 hammer loop + final "
                                        "empty cycle (possible lost/stuck edge -- CR-1 regression)\n");
                        failures++;
                    } else {
                        printf("ok: underrun_fired atomic under concurrent push/flush hammering\n");
                    }
                }

                if (hfd >= 0) close(hfd);
            }
        }

        pa_stream_set_underflow_callback(s, NULL, NULL);
    }

    /* Seek-armed flush tracer (D-02/D-03, Task 2, RESEARCH Pattern 1):
     * the single seek path proven end-to-end through the real HTTP
     * thread and real pa_stream_flush -- arm -> pre-flush bytes
     * withheld -> flush -> client stays attached -> only post-flush
     * bytes served. Byte-content proof via memcmp (Pitfall 3), not
     * merely connection-lifecycle. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int sfd = _test_connect_loopback(port);
        if (sfd < 0) {
            fprintf(stderr, "FAIL: could not connect client for seek-armed flush test\n");
            failures++;
        } else if (write(sfd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(sfd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach streaming client for seek-armed flush test\n");
            failures++;
            close(sfd);
        } else {
            /* Confirm the client is genuinely attached and draining
             * normally before arming anything. */
            float attachPattern[2] = { 0.5f, -0.5f };
            int32_t expected_attach[2];
            expected_attach[0] = _test_f32_to_s32(attachPattern[0]);
            expected_attach[1] = _test_f32_to_s32(attachPattern[1]);
            pa_stream_write(s, attachPattern, sizeof(attachPattern), NULL, 0, 0);

            unsigned char got_attach[8];
            if (_test_read_bytes(sfd, got_attach, sizeof(got_attach), 3000) != 0
                || memcmp(got_attach, expected_attach, sizeof(expected_attach)) != 0) {
                fprintf(stderr, "FAIL: seek-armed flush test: initial attach pattern never arrived or mismatched\n");
                failures++;
                close(sfd);
            } else if (!_test_post_control(port, "/seek-arm")) {
                fprintf(stderr, "FAIL: POST /seek-arm did not return 200 OK\n");
                failures++;
                close(sfd);
            } else {
                /* PRE-flush pattern -- must NOT reach the client while
                 * armed (drain gate holds). Confirm via a bounded
                 * poll/read window that literally zero bytes arrive and
                 * the socket does not see EOF either. */
                float prePattern[2] = { 0.75f, -0.75f };
                pa_stream_write(s, prePattern, sizeof(prePattern), NULL, 0, 0);

                int preLeaked = 0;
                int preEof = 0;
                {
                    unsigned char peek[64];
                    struct timeval ps, pn;
                    gettimeofday(&ps, NULL);
                    for (;;) {
                        struct pollfd pfd; pfd.fd = sfd; pfd.events = POLLIN;
                        int rc = poll(&pfd, 1, 20);
                        if (rc > 0) {
                            ssize_t n = read(sfd, peek, sizeof(peek));
                            if (n > 0) { preLeaked = 1; break; }
                            if (n == 0) { preEof = 1; break; }
                        }
                        gettimeofday(&pn, NULL);
                        if ((pn.tv_sec - ps.tv_sec) * 1000 >= 400) break;
                    }
                }

                /* Flush on the real stream handle -- armed, so the
                 * client must stay attached (no g_flush_disconnect). */
                pa_operation *flushOp = pa_stream_flush(s, NULL, NULL);
                if (flushOp) {
                    pa_operation_unref(flushOp);
                }

                /* POST-flush pattern -- the ONLY bytes that must reach
                 * the client. */
                float postPattern[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
                int32_t expected_post[4];
                for (int i = 0; i < 4; i++) {
                    expected_post[i] = _test_f32_to_s32(postPattern[i]);
                }
                pa_stream_write(s, postPattern, sizeof(postPattern), NULL, 0, 0);

                unsigned char got_post[16];
                int gotPost = (_test_read_bytes(sfd, got_post, sizeof(got_post), 3000) == 0);

                pthread_mutex_lock(&g_ring.lock);
                int stillConnected = g_ring.client_connected;
                pthread_mutex_unlock(&g_ring.lock);

                if (preLeaked) {
                    fprintf(stderr, "FAIL: seek-armed flush test: pre-flush bytes leaked to client before flush\n");
                    failures++;
                } else if (preEof) {
                    fprintf(stderr, "FAIL: seek-armed flush test: client saw EOF while armed and waiting (before flush)\n");
                    failures++;
                } else if (!gotPost) {
                    fprintf(stderr, "FAIL: seek-armed flush test: post-flush pattern never arrived\n");
                    failures++;
                } else if (memcmp(got_post, expected_post, sizeof(expected_post)) != 0) {
                    fprintf(stderr, "FAIL: seek-armed flush test: post-flush bytes mismatch (pre-flush bytes interleaved?)\n");
                    failures++;
                } else if (!stillConnected) {
                    fprintf(stderr, "FAIL: seek-armed flush test: client was disconnected (armed flush should not disconnect)\n");
                    failures++;
                } else {
                    printf("ok: seek-armed flush keeps client attached and serves only post-flush bytes\n");
                }

                close(sfd);
            }
        }
    }

    /* Leaked arm recovery (D-11, 77-REVIEWS.md HIGH): an arm with NO
     * flush ever following it must not wedge the drain gate shut past
     * a track/session boundary -- POST /boundary resets the stale arm
     * (see the reset in the boundary handler above) so the withheld
     * bytes still drain and the client still reaches a clean EOF at
     * the watermark, exactly as if no arm had ever been sent. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReq2[] = "GET /stream HTTP/1.0\r\n\r\n";
        int lfd = _test_connect_loopback(port);
        if (lfd < 0) {
            fprintf(stderr, "FAIL: could not connect client for leaked-arm boundary-reset test\n");
            failures++;
        } else if (write(lfd, getReq2, sizeof(getReq2) - 1) < 0
                   || _test_read_header(lfd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach streaming client for leaked-arm boundary-reset test\n");
            failures++;
            close(lfd);
        } else {
            float attachPattern2[2] = { 0.5f, -0.5f };
            int32_t expected_attach2[2];
            expected_attach2[0] = _test_f32_to_s32(attachPattern2[0]);
            expected_attach2[1] = _test_f32_to_s32(attachPattern2[1]);
            pa_stream_write(s, attachPattern2, sizeof(attachPattern2), NULL, 0, 0);

            unsigned char got_attach2[8];
            if (_test_read_bytes(lfd, got_attach2, sizeof(got_attach2), 3000) != 0
                || memcmp(got_attach2, expected_attach2, sizeof(expected_attach2)) != 0) {
                fprintf(stderr, "FAIL: leaked-arm test: initial attach pattern never arrived or mismatched\n");
                failures++;
                close(lfd);
            } else if (!_test_post_control(port, "/seek-arm")) {
                fprintf(stderr, "FAIL: leaked-arm test: POST /seek-arm did not return 200 OK\n");
                failures++;
                close(lfd);
            } else {
                /* This pattern is deliberately never flushed -- the arm
                 * leaks by design in this test, exercising the recovery
                 * path rather than the normal flush-consumption path. */
                float leakPattern[4] = { 0.6f, -0.6f, 0.4f, -0.4f };
                int32_t expected_leak[4];
                for (int i = 0; i < 4; i++) {
                    expected_leak[i] = _test_f32_to_s32(leakPattern[i]);
                }
                pa_stream_write(s, leakPattern, sizeof(leakPattern), NULL, 0, 0);

                int leaked = 0;
                int sawEofWhileArmed = 0;
                {
                    unsigned char peek[64];
                    struct timeval ps, pn;
                    gettimeofday(&ps, NULL);
                    for (;;) {
                        struct pollfd pfd; pfd.fd = lfd; pfd.events = POLLIN;
                        int rc = poll(&pfd, 1, 20);
                        if (rc > 0) {
                            ssize_t n = read(lfd, peek, sizeof(peek));
                            if (n > 0) { leaked = 1; break; }
                            if (n == 0) { sawEofWhileArmed = 1; break; }
                        }
                        gettimeofday(&pn, NULL);
                        if ((pn.tv_sec - ps.tv_sec) * 1000 >= 400) break;
                    }
                }

                /* Plant the boundary -- resets the leaked arm AND marks
                 * the current write cursor as the EOF watermark. */
                int boundary_ok = _test_post_control(port, "/boundary");

                if (leaked) {
                    fprintf(stderr, "FAIL: leaked-arm test: withheld bytes leaked to client before the boundary reset\n");
                    failures++;
                    close(lfd);
                } else if (sawEofWhileArmed) {
                    fprintf(stderr, "FAIL: leaked-arm test: client saw EOF while armed and waiting (before boundary reset)\n");
                    failures++;
                    close(lfd);
                } else if (!boundary_ok) {
                    fprintf(stderr, "FAIL: leaked-arm test: POST /boundary did not return 200 OK\n");
                    failures++;
                    close(lfd);
                } else {
                    /* Drain: the previously-withheld bytes must now
                     * flow (arm cleared by the boundary reset) and the
                     * client must reach a clean EOF exactly at the
                     * watermark -- same read-to-EOF idiom as the
                     * existing POST /boundary EOF test above. */
                    int got_eof = 0;
                    unsigned char received[64];
                    size_t received_n = 0;
                    for (int i = 0; i < 150 && !got_eof; i++) {
                        struct pollfd pfd; pfd.fd = lfd; pfd.events = POLLIN;
                        if (poll(&pfd, 1, 10) > 0) {
                            ssize_t n = read(lfd, received + received_n, sizeof(received) - received_n);
                            if (n == 0) {
                                got_eof = 1;
                            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                                got_eof = 1;
                            } else if (n > 0) {
                                received_n += (size_t)n;
                            }
                        }
                    }

                    if (!got_eof) {
                        fprintf(stderr, "FAIL: leaked-arm test: client never reached EOF at the watermark (hung)\n");
                        failures++;
                    } else if (received_n != sizeof(expected_leak)
                               || memcmp(received, expected_leak, sizeof(expected_leak)) != 0) {
                        fprintf(stderr, "FAIL: leaked-arm test: received %zu byte(s) at watermark, expected exactly the withheld pattern\n",
                                received_n);
                        failures++;
                    } else {
                        printf("ok: leaked arm cleared by boundary and client closes at watermark\n");
                    }

                    close(lfd);
                }
            }
        }
    }

    /* Rapid-skip last boundary wins (D-04, Plan 77-05 Task 1, RESEARCH
     * Pattern 2): two POST /boundary markers planted back-to-back, with
     * NO client attached during either plant -- so nothing can drain
     * and lock in the first watermark before the second lands. This
     * makes the assertion deterministic rather than a race against the
     * 50ms drain tick: the client attaches only AFTER both plants are
     * already resolved, so its very first drain pass already sees
     * whichever watermark is in effect. The existing plant-site
     * behavior (unconditional overwrite of g_boundary_at_pushed, no C
     * change needed for D-04) means that's the SECOND (later) marker --
     * proven here by requiring the client to receive chunk1+chunk2's
     * combined bytes (W2) before EOF, not just chunk1's (W1), which is
     * what a stale-first-marker bug would produce. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        /* chunk1 -- becomes W1's content once boundary #1 plants. */
        float chunk1[4] = { 0.3f, -0.3f, 0.2f, -0.2f };
        int32_t expected_chunk1[4];
        for (int i = 0; i < 4; i++) expected_chunk1[i] = _test_f32_to_s32(chunk1[i]);
        pa_stream_write(s, chunk1, sizeof(chunk1), NULL, 0, 0);

        int boundary1_ok = _test_post_control(port, "/boundary");  /* W1 */

        /* chunk2 -- pushed AFTER boundary #1 plants, BEFORE boundary #2
         * -- must be included once boundary #2 overwrites the watermark
         * to W2. No client is attached yet, so nothing has drained past
         * W1 in between -- this ordering is guaranteed, not raced. */
        float chunk2[4] = { 0.1f, -0.1f, 0.05f, -0.05f };
        int32_t expected_chunk2[4];
        for (int i = 0; i < 4; i++) expected_chunk2[i] = _test_f32_to_s32(chunk2[i]);
        pa_stream_write(s, chunk2, sizeof(chunk2), NULL, 0, 0);

        int boundary2_ok = _test_post_control(port, "/boundary");  /* W2 > W1, overwrites */

        if (!boundary1_ok || !boundary2_ok) {
            fprintf(stderr, "FAIL: rapid-skip test: a POST /boundary did not return 200 OK\n");
            failures++;
        } else {
            /* Attach the client only now -- AFTER both watermarks are
             * planted -- so the drain loop's first pass already sees
             * the LAST-planted (W2) marker, never the stale W1 one. */
            static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
            int rfd = _test_connect_loopback(port);
            if (rfd < 0) {
                fprintf(stderr, "FAIL: rapid-skip test: could not connect streaming client\n");
                failures++;
            } else if (write(rfd, getReq, sizeof(getReq) - 1) < 0
                       || _test_read_header(rfd, 3000) != 0) {
                fprintf(stderr, "FAIL: rapid-skip test: could not attach streaming client\n");
                failures++;
                close(rfd);
            } else {
                int got_eof = 0;
                unsigned char received[64];
                size_t received_n = 0;
                for (int i = 0; i < 150 && !got_eof; i++) {
                    struct pollfd pfd; pfd.fd = rfd; pfd.events = POLLIN;
                    if (poll(&pfd, 1, 10) > 0) {
                        ssize_t n = read(rfd, received + received_n, sizeof(received) - received_n);
                        if (n == 0) {
                            got_eof = 1;
                        } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                            got_eof = 1;
                        } else if (n > 0) {
                            received_n += (size_t)n;
                        }
                    }
                }
                close(rfd);

                unsigned char expected_combined[sizeof(expected_chunk1) + sizeof(expected_chunk2)];
                memcpy(expected_combined, expected_chunk1, sizeof(expected_chunk1));
                memcpy(expected_combined + sizeof(expected_chunk1), expected_chunk2, sizeof(expected_chunk2));
                size_t expected_n = sizeof(expected_combined);

                if (!got_eof) {
                    fprintf(stderr, "FAIL: rapid-skip test: client never reached EOF (hung)\n");
                    failures++;
                } else if (received_n != expected_n) {
                    fprintf(stderr, "FAIL: rapid-skip test: received %zu byte(s), expected exactly %zu "
                                    "(W2's combined chunk1+chunk2 -- a stale W1 would stop at %zu)\n",
                            received_n, expected_n, sizeof(expected_chunk1));
                    failures++;
                } else if (memcmp(received, expected_combined, expected_n) != 0) {
                    fprintf(stderr, "FAIL: rapid-skip test: received bytes mismatch (wrong watermark applied?)\n");
                    failures++;
                } else {
                    printf("ok: rapid-skip last boundary wins\n");
                }
            }
        }
    }

    /* Takeover during armed window serves no pre-flush bytes (D-05/D-02,
     * Plan 77-05 Task 2, RESEARCH Pitfall 3): a NEW client attaches via
     * the pre-existing, arm-independent GET /stream takeover logic WHILE
     * a seek-arm is pending -- Plan 77-01's drain-loop write gate must
     * hold through the takeover too, not just for whichever client was
     * attached when the arm landed. Client 2 must receive ZERO bytes of
     * whatever is pushed pre-flush (withheld, then discarded by the
     * flush itself), and its first bytes after the flush must be
     * exactly the post-flush pattern -- memcmp-proven, not merely
     * "still connected" (Pitfall 3's own content-assertion requirement). */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";

        int c1fd = _test_connect_loopback(port);
        if (c1fd < 0) {
            fprintf(stderr, "FAIL: takeover-armed test: could not connect client 1\n");
            failures++;
        } else if (write(c1fd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(c1fd, 3000) != 0) {
            fprintf(stderr, "FAIL: takeover-armed test: could not attach client 1\n");
            failures++;
            close(c1fd);
        } else {
            float attachPattern[2] = { 0.5f, -0.5f };
            int32_t expected_attach[2];
            expected_attach[0] = _test_f32_to_s32(attachPattern[0]);
            expected_attach[1] = _test_f32_to_s32(attachPattern[1]);
            pa_stream_write(s, attachPattern, sizeof(attachPattern), NULL, 0, 0);

            unsigned char got_attach[8];
            if (_test_read_bytes(c1fd, got_attach, sizeof(got_attach), 3000) != 0
                || memcmp(got_attach, expected_attach, sizeof(expected_attach)) != 0) {
                fprintf(stderr, "FAIL: takeover-armed test: client 1 did not attach/drain normally\n");
                failures++;
                close(c1fd);
            } else if (!_test_post_control(port, "/seek-arm")) {
                fprintf(stderr, "FAIL: takeover-armed test: POST /seek-arm did not return 200 OK\n");
                failures++;
                close(c1fd);
            } else {
                /* Client 2 takes over WHILE armed -- the existing GET
                 * /stream takeover logic (unconditional, independent of
                 * arm state) closes client 1 and promotes client 2. */
                int c2fd = _test_connect_loopback(port);
                if (c2fd < 0) {
                    fprintf(stderr, "FAIL: takeover-armed test: could not connect client 2\n");
                    failures++;
                    close(c1fd);
                } else if (write(c2fd, getReq, sizeof(getReq) - 1) < 0
                           || _test_read_header(c2fd, 3000) != 0) {
                    fprintf(stderr, "FAIL: takeover-armed test: could not attach client 2 (takeover)\n");
                    failures++;
                    close(c1fd);
                    close(c2fd);
                } else {
                    /* Client 1 is superseded by the takeover; the
                     * takeover mechanism itself is pre-existing and
                     * host-tested elsewhere -- this test's focus is the
                     * drain gate holding across it, not the takeover
                     * mechanics themselves. */
                    close(c1fd);

                    /* PRE-flush pattern -- pushed AFTER client 2's
                     * takeover, while still armed. Must NOT reach
                     * client 2 (drain gate withholds all pops while
                     * armed, Plan 77-01's Pitfall-3 fix) and must not
                     * disconnect it either. */
                    float prePattern[2] = { 0.75f, -0.75f };
                    pa_stream_write(s, prePattern, sizeof(prePattern), NULL, 0, 0);

                    int preLeaked = 0;
                    int preEof = 0;
                    {
                        unsigned char peek[64];
                        struct timeval ps, pn;
                        gettimeofday(&ps, NULL);
                        for (;;) {
                            struct pollfd pfd; pfd.fd = c2fd; pfd.events = POLLIN;
                            int rc = poll(&pfd, 1, 20);
                            if (rc > 0) {
                                ssize_t n = read(c2fd, peek, sizeof(peek));
                                if (n > 0) { preLeaked = 1; break; }
                                if (n == 0) { preEof = 1; break; }
                            }
                            gettimeofday(&pn, NULL);
                            if ((pn.tv_sec - ps.tv_sec) * 1000 >= 400) break;
                        }
                    }

                    /* Flush -- armed, so client 2 stays attached; the
                     * withheld pre-flush pattern is discarded by the
                     * flush itself (_ring_flush), never delivered. */
                    pa_operation *flushOp = pa_stream_flush(s, NULL, NULL);
                    if (flushOp) {
                        pa_operation_unref(flushOp);
                    }

                    /* POST-flush pattern -- the ONLY bytes that must
                     * reach client 2. */
                    float postPattern[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
                    int32_t expected_post[4];
                    for (int i = 0; i < 4; i++) {
                        expected_post[i] = _test_f32_to_s32(postPattern[i]);
                    }
                    pa_stream_write(s, postPattern, sizeof(postPattern), NULL, 0, 0);

                    unsigned char got_post[16];
                    int gotPost = (_test_read_bytes(c2fd, got_post, sizeof(got_post), 3000) == 0);

                    pthread_mutex_lock(&g_ring.lock);
                    int stillConnected = g_ring.client_connected;
                    pthread_mutex_unlock(&g_ring.lock);

                    if (preLeaked) {
                        fprintf(stderr, "FAIL: takeover-armed test: pre-flush bytes leaked to client 2 during the armed window\n");
                        failures++;
                    } else if (preEof) {
                        fprintf(stderr, "FAIL: takeover-armed test: client 2 saw EOF while armed and waiting (before flush)\n");
                        failures++;
                    } else if (!gotPost) {
                        fprintf(stderr, "FAIL: takeover-armed test: post-flush pattern never arrived at client 2\n");
                        failures++;
                    } else if (memcmp(got_post, expected_post, sizeof(expected_post)) != 0) {
                        fprintf(stderr, "FAIL: takeover-armed test: client 2's first bytes mismatch (pre-flush bytes interleaved?)\n");
                        failures++;
                    } else if (!stillConnected) {
                        fprintf(stderr, "FAIL: takeover-armed test: client 2 was disconnected (armed flush across a takeover should not disconnect)\n");
                        failures++;
                    } else {
                        printf("ok: takeover during armed window serves no pre-flush bytes\n");
                    }

                    close(c2fd);
                }
            }
        }
    }

    /* Double seek-arm double flush (RESEARCH Open Question 1, locked by
     * Plan 77-01's saturating-counter design): two POST /seek-arm
     * requests land back-to-back BEFORE either flush consumes an arm --
     * the counter (not a one-shot bool) must honor BOTH, keeping the
     * client attached across BOTH flushes. A THIRD, un-armed flush
     * afterward must restore ordinary D-12 disconnect semantics -- the
     * counter cannot leak into permanently suppressing skip behavior
     * (T-77-11). */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int dfd = _test_connect_loopback(port);
        if (dfd < 0) {
            fprintf(stderr, "FAIL: double-flush test: could not connect client\n");
            failures++;
        } else if (write(dfd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(dfd, 3000) != 0) {
            fprintf(stderr, "FAIL: double-flush test: could not attach client\n");
            failures++;
            close(dfd);
        } else {
            float attachPattern[2] = { 0.5f, -0.5f };
            int32_t expected_attach[2];
            expected_attach[0] = _test_f32_to_s32(attachPattern[0]);
            expected_attach[1] = _test_f32_to_s32(attachPattern[1]);
            pa_stream_write(s, attachPattern, sizeof(attachPattern), NULL, 0, 0);

            unsigned char got_attach[8];
            if (_test_read_bytes(dfd, got_attach, sizeof(got_attach), 3000) != 0
                || memcmp(got_attach, expected_attach, sizeof(expected_attach)) != 0) {
                fprintf(stderr, "FAIL: double-flush test: client did not attach/drain normally\n");
                failures++;
                close(dfd);
            } else if (!_test_post_control(port, "/seek-arm")
                       || !_test_post_control(port, "/seek-arm")) {
                fprintf(stderr, "FAIL: double-flush test: a POST /seek-arm did not return 200 OK\n");
                failures++;
                close(dfd);
            } else {
                /* First flush -- consumes one of the two arms; client
                 * must stay attached. */
                pa_operation *flush1 = pa_stream_flush(s, NULL, NULL);
                if (flush1) pa_operation_unref(flush1);

                /* Second flush -- consumes the second arm; client must
                 * STILL stay attached (Open Question 1's actual answer:
                 * the counter honors both arms, not just the first). */
                pa_operation *flush2 = pa_stream_flush(s, NULL, NULL);
                if (flush2) pa_operation_unref(flush2);

                pthread_mutex_lock(&g_ring.lock);
                int connectedAfterTwoFlushes = g_ring.client_connected;
                pthread_mutex_unlock(&g_ring.lock);

                /* Audio pushed after the second flush must reach the
                 * still-attached client normally. */
                float postPattern[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
                int32_t expected_post[4];
                for (int i = 0; i < 4; i++) {
                    expected_post[i] = _test_f32_to_s32(postPattern[i]);
                }
                pa_stream_write(s, postPattern, sizeof(postPattern), NULL, 0, 0);

                unsigned char got_post[16];
                int gotPost = (_test_read_bytes(dfd, got_post, sizeof(got_post), 3000) == 0);

                if (!connectedAfterTwoFlushes) {
                    fprintf(stderr, "FAIL: double-flush test: client was disconnected after only the SECOND armed flush (counter did not honor both arms)\n");
                    failures++;
                    close(dfd);
                } else if (!gotPost) {
                    fprintf(stderr, "FAIL: double-flush test: post-second-flush pattern never arrived\n");
                    failures++;
                    close(dfd);
                } else if (memcmp(got_post, expected_post, sizeof(expected_post)) != 0) {
                    fprintf(stderr, "FAIL: double-flush test: post-second-flush bytes mismatch\n");
                    failures++;
                    close(dfd);
                } else {
                    /* Third flush -- UN-armed (both prior arms already
                     * consumed) -- must restore ordinary D-12
                     * disconnect: the client must reach a real EOF. */
                    pa_operation *flush3 = pa_stream_flush(s, NULL, NULL);
                    if (flush3) pa_operation_unref(flush3);

                    int got_eof = 0;
                    for (int i = 0; i < 100 && !got_eof; i++) {
                        struct pollfd pfd; pfd.fd = dfd; pfd.events = POLLIN;
                        int prc = poll(&pfd, 1, 10);
                        if (prc > 0) {
                            unsigned char sink[256];
                            ssize_t n = read(dfd, sink, sizeof(sink));
                            if (n == 0) {
                                got_eof = 1;
                            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                                got_eof = 1;
                            }
                        }
                    }
                    close(dfd);

                    if (!got_eof) {
                        fprintf(stderr, "FAIL: double-flush test: third (un-armed) flush did not disconnect the client within 1s -- D-12 not restored\n");
                        failures++;
                    } else {
                        printf("ok: double seek-arm double flush keeps client attached\n");
                    }
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

        size_t nfloats = (RING_CAPACITY / sizeof(int32_t)) + 1000;
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
