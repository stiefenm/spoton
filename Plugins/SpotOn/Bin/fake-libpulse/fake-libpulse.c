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

/* 84-17 (found live in the long-tail proof): the daemon writes one whole
 * chunk whenever pa_stream_writable_size() is > 0, whatever the chunk size
 * (seen: a 7136 B write at 5456 B free, 8192 B at 6512 and 3552). Told the
 * truthful free space it therefore overshoots the ring by up to a chunk at
 * every full-ring stall. A write that has to WAIT inside the shim blocks the
 * daemon's thread, and a daemon thread parked there answers nothing (the
 * get_auth_state health probe went unanswered: `no_answer`, a restart). So
 * the size the daemon is TOLD keeps this reserve back: it sees 0 once the free
 * space is at or below it, stops writing on its own (as it did in the old
 * measurement, ~10 s, until LMS read the ring again), and its last chunk lands
 * in the reserve. 128 KiB = 0.37 s of audio, >= 15 chunks of the largest seen
 * (8192 B). No memory is added; the ring is the same 20 s, the daemon is
 * told 19.63 s. The waiting writer in _ring_push stays as the backstop for an
 * overshoot beyond the reserve (never expected). */
#define RING_WRITE_MARGIN (128 * 1024)

/* 84-20 (Q2): depth of the virtual sink in ms (see the block after
 * _mono_ms). Measured, not chosen: the smallest T of {2000..5000} whose
 * transfer-in passed twice and whose title-end and browse-seek passed once
 * (84-20-VSINK.md). SPOTON_FAKEPULSE_VSINK_MS overrides it, 0 = off = the
 * 84-17 contract. A rollback sets this to 0 in the surviving source. */
#define VSINK_MS_DEFAULT 3000

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
static atomic_int g_debug_trace;   /* 84-22: atomic_int -- the harness switches the level while the HTTP thread reads it (plain `=` / reads stay atomic) */

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
 * 84-22: atomic_int, no longer volatile. It used to be read only at the top
 * of _http_thread_fn's loop; the client write (_http_write_client) now reads
 * it every tick to end a stalled write through the flush path, so the flag is
 * touched by the HTTP thread in two places and written by the flush caller.
 * Plain `=` and plain reads on an _Atomic int are seq_cst atomic operations
 * (the g_seek_flush_armed / g_ring_underrun_fired precedent below), so no
 * access site changes. */
static atomic_int g_flush_disconnect = 0;

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

/* WR-03 (77-REVIEW): while an arm is pending, the drain-loop gate below
 * withholds ALL audio -- the ring fills (~20s), Soloist stops writing,
 * position freezes, and the track never reaches the natural-EOF/session
 * boundary that is otherwise the only thing that clears a leaked arm
 * (POST /boundary's unconditional reset). An arm is only ever meaningful
 * for the sub-second window between POST /seek-arm landing and Soloist's
 * own pa_stream_flush() consuming it -- stamp the wall-clock time of the
 * most recent /seek-arm and let the drain loop expire (zero) the counter
 * if that window is grossly exceeded, so a leaked arm self-heals instead
 * of wedging playback until the next track boundary (which the leak
 * itself prevents from ever arriving). HTTP-thread-only (both the stamp
 * in the /seek-arm handler and the check in the drain loop run on this
 * same thread), so a plain struct timeval needs no atomic/lock
 * protection. */
static struct timeval g_seek_arm_at;
#define SEEK_ARM_TTL_MS 3000

/* 79-47 (D-34, user decision "beta.2: auch App-Uebernahme"): browse keep.
 * In browse (LMS owns the playlist) an app seek, and an app next/previous
 * before Control redirects it to LMS, makes the daemon flush on its own. An
 * unarmed flush is treated as a title boundary below (g_flush_disconnect):
 * it closed LMS's stream about 41 ms later, LMS read EOF and played the next
 * item (.planning/debug/pi-group-connect-seek-pause.md, 79-46 Case F).
 * Control's own browse title changes never need that disconnect: its plays
 * are armed (Control.pm _reconcilePlan, armed whenever a track is observed),
 * a natural end is ended by the drain POST /boundary, and an LMS skip opens a
 * new GET /stream (takeover). So while browse keep is set an UNARMED flush
 * keeps the client, exactly as an armed flush does, without touching the
 * seek-arm counter (whose drain gate would withhold audio until its TTL).
 * Set and cleared ONLY by POST /browse-keep?on=1 / ?on=0 (Control, 79-48);
 * without that POST the shim behaves as before 79-47. Not reset by
 * /boundary, a client change or a timeout: Control owns it for the whole
 * browse session and clears it when it leaves browse (Connect app skips
 * still need the unarmed disconnect). Single writer: the HTTP thread (the
 * POST handler); read by the flush caller's thread in pa_stream_flush --
 * atomic_int, the g_seek_flush_armed precedent. */
static atomic_int g_browse_keep = 0;

/* 79-50 (D-34 R2): the connect decision window. In a Connect session an app
 * seek makes the daemon flush on its own, the flush is unarmed, and the
 * disconnect it raises used to run at the HTTP thread's next wake-up, 9 ms
 * later (79-47 R2, R2_3: close 18:01:11.518 for a flush at 18:01:11.509).
 * Control only learns that the flush was a seek from the daemon's first frame,
 * 6-7 ms after the flush (E1), and an app skip looks exactly the same to the
 * shim at flush time (E3: cork 0->1 and a flush with corked=1 in one
 * millisecond, both). So an unarmed, not-browse-kept flush stamps a decision
 * deadline (now + W) BEFORE it raises g_flush_disconnect, and the HTTP thread
 * holds the disconnect open until the decision is final:
 *   - POST /seek-keep (Control, a buffering frame on the unchanged title)
 *     keeps the client: the flag and the deadline are cleared;
 *   - POST /boundary (Control, track_changed = the skip) or the deadline ends
 *     the window: the disconnect runs as before;
 *   - a late /seek-arm consumed by the pending disconnect and a takeover (a
 *     new GET /stream) end it too (every canceller of g_flush_disconnect also
 *     clears the deadline).
 * The window is OPEN iff g_flush_disconnect is set AND the deadline lies in
 * the future (_flush_decide_open). While it is open the drain pops nothing (the
 * post-flush audio is withheld) and the client write is never cut. W is
 * SPOTON_FAKEPULSE_FLUSH_DECIDE_MS (read by the flush caller thread, like
 * _hold_gap_env_ms), 0..5000, 0 = no window, unset or invalid = 2000: a skip
 * ends by its /boundary whatever W is, so the deadline only decides when no
 * signal arrives at all (Control stalled or dead), and a larger W lets a
 * stalled Control still deliver its keep at no cost beyond a later close of a
 * stream that would close anyway. The deadline is a wrap-safe _mono_ms() value
 * (atomic_long: lock-free on every target, armhf included), 0 = none. */
#define FLUSH_DECIDE_MS_DEFAULT 2000
#define FLUSH_DECIDE_MS_MAX     5000
static atomic_long g_flush_decide_deadline = 0;   /* _mono_ms() deadline, 0 = no window */
static atomic_long g_flush_decide_t0 = 0;          /* _mono_ms() of the flush that opened it, 0 = none */
static atomic_int  g_flush_decide_promoted = 0;    /* 1 = ended by POST /boundary (the skip) */

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

/* boundary-trifft-nachfolgeclient fix (debug session 2026-09-22,
 * .planning/debug/boundary-trifft-nachfolgeclient.md): a boundary
 * planted above is a bare ring position -- by itself it says nothing
 * about WHICH client it was meant to bound. Without an identity check,
 * whichever fd happens to occupy the single client_fd slot when the
 * ring catches up to that position gets closed, even if that client
 * attached AFTER the boundary was planted (i.e. it is already the NEXT
 * track's client, not the one the boundary was meant for) -- this was
 * the confirmed root cause, isolated in a live measurement (fd=45
 * attaching 10ms after boundary_planted, closed 603ms later by a
 * boundary meant for its predecessor).
 *
 * Fix: a generation counter, bumped on every successful client takeover
 * (the single `client_fd = pending.fd;` assignment below, the one place
 * in this file a new client is ever promoted). POST /boundary snapshots
 * the CURRENT generation alongside the ring position; at
 * boundary-reached, the marker is only allowed to close client_fd if
 * the generation still matches -- i.e. the client attached at plant
 * time is still the client attached now. Any mismatch means a takeover
 * happened in between and the marker is stale: discard it (reset to
 * -1) WITHOUT closing, so the new client's stream is left alone.
 *
 * client_fd < 0 at plant time (no client attached when POST /boundary
 * arrives) is recorded as generation NO_CLIENT_GENERATION, a sentinel.
 * REVISED design decision (the first attempt below was wrong -- kept
 * here, corrected, per the debugging philosophy of not hiding a
 * disproven hypothesis): the initial choice was Reading A ("discard --
 * a later client must not inherit it"), reasoning that Reading B ("the
 * next attacher inherits it") is the confirmed defect. That is true
 * ONLY when a specific predecessor client existed and was superseded --
 * but when NO client EVER attached during planting, there is no
 * predecessor to protect, and the pre-existing, DELIBERATELY-tested D-04
 * "rapid-skip last boundary wins" behavior (Plan 77-05, commit
 * 82a25b0, host test "rapid-skip last boundary wins") specifically
 * requires that in THIS exact precondition (two POST /boundary calls
 * back-to-back with no client attached to either), the first client to
 * attach afterward DOES inherit the most-recently-planted marker.
 * Blind Reading A broke that pre-existing test outright (client hung,
 * never reached EOF) the first time `make test` ran against this fix --
 * a real regression caught by the existing suite, not a hypothetical.
 * The corrected rule: NO_CLIENT_GENERATION means "no specific
 * predecessor to protect" -- the marker applies unconditionally
 * (matches pre-fix/D-04 behavior). Only a REAL, non-sentinel planted
 * generation that no longer matches the current one triggers a
 * discard -- that is precisely and only the confirmed defect's
 * precondition (a live client existed, then got superseded). This
 * cannot suppress a legitimate EOF for the takeover case: LMS opens one
 * GET /stream connection per track (ProtocolHandler.pm:296-303 -- g=<gen>
 * is LMS-side URL-uniqueness decoration only, this file never parses
 * query strings), so a reconnect after a full disconnect is always a
 * NEW logical request (next track, or a retry LMS treats as new) --
 * never a resumption still waiting on the OLD boundary. Same-track
 * repositioning goes through the separate /seek-arm path, not
 * /boundary, so it never competes with this mechanism.
 *
 * Ownership/locking: like g_boundary_at_pushed itself, both new
 * variables are written and read EXCLUSIVELY by _http_thread_fn -- the
 * POST /boundary handler (write, generation snapshot only) and the
 * takeover block (write, generation increment only) and the drain
 * loop's boundary check (read of both) are all the same thread, same
 * loop, same as client_fd itself (a plain non-volatile local there).
 * Unlike g_boundary_at_pushed, no pa_stream_* callback on Soloist's own
 * writer thread ever touches these two new fields -- only
 * g_boundary_at_pushed itself gets invalidated cross-thread (flush,
 * stream-recreate, session teardown all just set IT to -1), and every
 * consumption site is already gated on `if (boundary >= 0)` first, so a
 * cross-thread reset of g_boundary_at_pushed alone is sufficient to
 * invalidate the whole marker -- the generation fields are simply never
 * read once boundary is -1, regardless of what stale value they hold.
 * No pthread_mutex_t is needed for either field (g_ring.lock protects
 * the RING, not this bookkeeping, same as g_boundary_at_pushed itself);
 * `volatile` matches the existing style/rationale for
 * g_boundary_at_pushed (defeat compiler caching across the
 * poll()/read() calls within the loop) even though, unlike
 * g_boundary_at_pushed, strictly nothing outside this one thread ever
 * observes them -- belt-and-suspenders, not a correctness requirement
 * for the single-thread-owned case. */
#define NO_CLIENT_GENERATION ((int64_t)-1)
static volatile int64_t g_client_generation = 0;
static volatile int64_t g_boundary_client_generation = NO_CLIENT_GENERATION;

/* boundary-trifft-nachfolgeclient REOPENED (.planning/debug/
 * boundary-trifft-nachfolgeclient.md, "WIEDERERÖFFNET" section): the fix
 * above only covers ONE of two orderings in which a boundary can be
 * planted with client_fd < 0. Live measurement 2026-09-22 15:15:48 found
 * the other one still closing the wrong client, on a POSITIVELY confirmed
 * natural track end:
 *
 *   .237  client-close: write error/disconnect   (predecessor dies FIRST,
 *                                                  unnoticed by anyone but
 *                                                  this thread's own next
 *                                                  write attempt)
 *   .237  boundary_planted gen=-1                 (NO_CLIENT_GENERATION --
 *                                                  client_fd was already
 *                                                  -1 by the time the
 *                                                  POST /boundary for
 *                                                  THIS SAME track
 *                                                  transition arrived)
 *   .243  client-attach fd=43                     (successor -- the NEXT
 *                                                  track's client)
 *   .795  boundary_reached: closing client fd=43  (DEFECT -- successor
 *                                                  truncated after 12560
 *                                                  bytes)
 *
 * The trap: this has the IDENTICAL observable precondition at plant time
 * (client_fd < 0) as the D-04 "rapid-skip last boundary wins" case (Plan
 * 77-05, commit 82a25b0) and as the file's own former "no-client-at-plant"
 * test (see that test's corrected comment below) -- in both, nobody is
 * attached when POST /boundary arrives. But the two cases mean opposite
 * things:
 *
 *   - D-04: no client EVER attached in the whole window between two
 *     back-to-back plants -- there is no predecessor at all, so "last
 *     boundary wins" unconditionally is correct (matches pre-fix
 *     behavior, deliberately preserved by the first fix's
 *     NO_CLIENT_GENERATION branch).
 *   - Here: a REAL predecessor client WAS attached and departed --
 *     abruptly, via a failed write, not via this file's own
 *     boundary_reached/takeover close paths -- and the departure merely
 *     raced the POST /boundary that (per SoloistWS's WS track_changed
 *     handler) was meant to bound exactly that predecessor's stream. The
 *     marker still belongs to the departed client and must NOT be
 *     inherited by whoever attaches next.
 *
 * A generation counter that also increments on detach was considered and
 * rejected: D-04's two plants have neither an attach nor a detach between
 * them, so bumping on detach would still leave both cases looking
 * identical to the plant handler -- it does not add the missing bit of
 * information (WAS there ever a specific predecessor to protect, even
 * though it is gone by plant time).
 *
 * Fix: track the generation of the most recently ABRUPTLY-departed client
 * (write-error close, and since debug connect-skip-prev-ton-bleibt also
 * the flush-disconnect close -- see the correction below) in
 * g_departed_client_generation, separately from g_boundary_client_generation.
 * At plant time, when client_fd < 0:
 *   - if a departed generation is on record (non-sentinel), the marker
 *     inherits THAT generation (a real, specific predecessor to protect)
 *     and the record is consumed (reset to NO_CLIENT_GENERATION) --
 *     one-shot, so it cannot also attach itself to some later, unrelated
 *     plant if no client ever reattaches in between;
 *   - otherwise (truly nobody, ever) it stays NO_CLIENT_GENERATION,
 *     exactly the D-04 case, unconditionally inherited by the next
 *     attacher as before.
 * The record is also cleared (without being consumed into a marker) the
 * moment ANY new client successfully attaches (takeover block below) --
 * a live attach means the story has moved on; an unconsumed departed
 * generation from further back must not leak forward into some much
 * later plant that has nothing to do with it. This is what makes the
 * one-shot property actually one-shot across a whole session rather than
 * only across a single plant/attach pair.
 *
 * Deliberately NOT set by the takeover-close path (client_fd >= 0 at the
 * moment a NEW connection completes its head -- fake-libpulse.c's own
 * WR-11 supersede semantics): that close is immediately followed, same
 * iteration, same code block, by the new client's promotion -- there is
 * no window in which client_fd is observably -1 for a plant to race, so
 * there is nothing here for a departed-generation record to protect
 * against.
 *
 * CORRECTED (debug connect-skip-prev-ton-bleibt, 2026-09-24, decision
 * 2A): the flush-disconnect path (top of loop) used to CLEAR this record,
 * on the premise that "that close already wipes g_boundary_at_pushed in
 * the same event, so there is no marker left to misattribute". The
 * premise was false: the wipe only covers a marker planted BEFORE the
 * close, but the skip's own POST /boundary is sent on WS track_changed,
 * which FOLLOWS the flush -- it is planted AFTER the flush-disconnect,
 * with no client attached, at a ring position that already holds the
 * next title's first bytes. Measured three times (2026-09-24 12:01:37
 * LMS previous -> previous title, 12:10:00 LMS next, and the app skip of
 * todo connect-app-skip-nach-uebergabe-endet-in-lms-stop): `gen=-1
 * via=none`, inherited by LMS' fresh stream, closed after 16384 bytes.
 * The flush-disconnect path now RECORDS the closed client's generation,
 * like the write-error close: such a marker belongs to the departed
 * stream only and is discarded once the next client attached. D-04 is
 * unaffected (no close between its plants). Known uncovered orderings
 * (neither observed in any measurement): (1) the next title's client
 * attaching BEFORE the old title's /boundary arrives -- the attach
 * clears the record and the plant then sees a live client; (2) a second
 * unarmed skip before any client re-attached -- the first plant consumed
 * the record (one-shot), the second is planted via=none.
 *
 * CORRECTED AGAIN (79-51 runaway D2, 2026-10-27, .planning/debug/album-start-
 * connect-runaway.md E4/E5): the bounded-EOF closes (pre-pop and post-pop) now
 * RECORD their client too, like the write-error and flush-disconnect closes.
 * Measured case (E4, 094204): client g=15 closed at 25.106, the next plant at
 * 25.328 had nobody attached and an empty ring (`gen=-1 via=none ring_fill=0`),
 * LMS's fresh client attached at 25.338 and was closed in the same millisecond
 * (`wrote=0`); LMS stopped and the stop was forwarded as the daemon's pause.
 * With the record that plant reads via=departed and its marker belongs to the
 * departed client, so the next attach discards it (stale generation). The cost,
 * stated honestly: the record is made on EVERY bounded close, a normal title end
 * included. Without a flush, a plant made after a bounded close and before the
 * next attach therefore no longer bounds that attacher (cell D2-C7, T-79-195);
 * after a flush (every real skip) the bytes before the marker belong to the next
 * title and discarding is right (cell D2-C6, the 3346f9e reasoning). Known
 * uncovered ordering (2) above (a second plant before any attach) is handled
 * only by the orphan discard at promotion (E5: 094408 :20.536/.550, no predecessor
 * at all), and only when the marker sits at or below total_popped (the ring was
 * empty at the plant, the measured burst shape); bytes pushed between the flush
 * and that plant keep the old bound. D-04 (a marker ABOVE total_popped with no
 * departed record) is untouched.
 *
 * Ownership/locking: same rationale as g_client_generation and
 * g_boundary_client_generation above -- written and read EXCLUSIVELY by
 * _http_thread_fn (the write-error-close branch of the drain loop, the
 * takeover block, the flush-disconnect block, and the POST /boundary
 * plant handler are all the same thread, same loop). No pthread_mutex_t
 * needed; `volatile` only to defeat compiler caching across the
 * poll()/read() calls within the loop, same as its siblings. */
static volatile int64_t g_departed_client_generation = NO_CLIENT_GENERATION;

typedef struct {
    unsigned char  *buf;
    size_t          capacity;
    size_t          head;   /* next write offset */
    size_t          tail;   /* next read offset */
    size_t          fill;   /* bytes currently held */
    int64_t         total_pushed;  /* cumulative S32LE bytes pushed (monotonic, Phase 77 Spike 2) */
    int64_t         total_popped;  /* cumulative S32LE bytes popped (monotonic, Phase 77 Spike 2) */
    /* 84-17: total_pushed at the moment an EMPTY ring was last refilled
     * (-1 = never since the last ring flush). A natural title end leaves
     * the ring empty before the next title's prebuffer is pushed, so this
     * is the position where the old title ended -- the drain anchor of
     * POST /boundary?anchor=drain. Written under the ring lock. */
    int64_t         last_empty_pushed;
    /* 84-17: cumulative bytes discarded by the drop-oldest branch of
     * _ring_push (never reset; reported by write_summary and the
     * POST /boundary reply so a drop is visible instead of silent). */
    int64_t         drops_total;
    /* 84-17 (backpressure, user decision "never discard, the daemon
     * waits"): a full ring never discards -- the writer waits on
     * space_avail. flush_epoch is bumped by every flush and by stream
     * teardown; a writer that sees it change abandons the rest of its
     * chunk (it is audio of the old title). flushed_away counts those
     * intentionally abandoned bytes (NOT a loss, never in drops_total). */
    uint64_t        flush_epoch;
    int64_t         flushed_away;
    int             client_connected;
    pthread_mutex_t lock;
    pthread_cond_t  data_avail;  /* signaled when bytes are pushed */
    pthread_cond_t  space_avail; /* signaled when bytes are popped (Phase 78: backpressure) */
    /* 79-07 (84 WR-01): the number of threads currently inside
     * pa_stream_write(), and the condition the teardown waits on until that
     * number reaches zero. Both under `lock`. The stream may only be freed
     * once no writer can still touch it. */
    int             writers_in;
    pthread_cond_t  writers_gone;
    /* 79-37 (79 D-31): the gap hold. After a write gap of at least
     * hold_gap_ms with the same live client (a natural title end leaves the
     * ring empty for ~3 s before the next title's burst), the first push
     * arms a hold at the old title's end (hold_at = total_pushed before that
     * push); the pop is capped at hold_at until Control's drain POST plants
     * the boundary there, or the hold times out / is flushed / is released.
     * Everything below is read and written under `lock`.
     *
     * Every time is a 64-bit millisecond value (_hold_now_ms) with its own
     * validity flag: on armhf `long` is 32 bits and _mono_ms() wraps after
     * ~24.8 days of uptime, so "> 0" on a time is never a validity test. */
    int             empty_valid;        /* 1 = the ring was emptied by a pop (client attached) */
    int64_t         empty_since_ms;     /* valid only with empty_valid */
    int64_t         hold_at;            /* ring position of the old title's end; -1 = no hold */
    int64_t         hold_since_ms;      /* valid only with hold_at >= 0 */
    long            hold_max_ms;        /* HOLD_MS in force (stored by the writer thread) */
    long            hold_gap_ms;        /* HOLD_GAP_MS in force (0 = off; stored by the writer thread) */
    int             suppress_valid;     /* 1 = the next arming is skipped until hold_suppress_until_ms */
    int64_t         hold_suppress_until_ms;
    int64_t         hold_expired_at;    /* hold_at of this client's last timed-out hold; -1 = none */
    int64_t         hold_armed_total;   /* holds armed since start (harness) */
    int64_t         client_gen_copy;    /* g_client_generation as of the attach (log only) */
    char            hold_last_release[16]; /* reason of the last release (harness) */
} ring_buffer_t;

/* 79-37 D-31 defaults (discretion, named in the plan): the gap must stay at or
 * below half the vsink T (3000 ms), far above the ~20-40 ms empty edges of
 * steady playback, far below the 2.9 s minimum measured natural-end gap. */
#define HOLD_GAP_MS_DEFAULT 500
#define HOLD_MS_DEFAULT     450

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
/* 84-17: last pa_stream_writable_size value and when (CLOCK_MONOTONIC ms),
 * written by the daemon's thread, read by it in pa_stream_write's log line. */
static volatile size_t g_last_writable_reported = 0;
static volatile long   g_last_writable_query_ms = 0;

static void _ring_init(ring_buffer_t *r) {
    r->buf = malloc(RING_CAPACITY);
    r->capacity = RING_CAPACITY;
    r->head = r->tail = r->fill = 0;
    r->total_pushed = 0;  /* Phase 77 Spike 2: monotonic, never reset by flush */
    r->total_popped = 0;
    r->last_empty_pushed = -1;
    r->drops_total = 0;
    r->flush_epoch = 0;
    r->flushed_away = 0;
    r->client_connected = 0;
    r->writers_in = 0;
    r->empty_valid = 0;
    r->empty_since_ms = 0;
    r->hold_at = -1;
    r->hold_since_ms = 0;
    r->hold_max_ms = HOLD_MS_DEFAULT;
    r->hold_gap_ms = HOLD_GAP_MS_DEFAULT;
    r->suppress_valid = 0;
    r->hold_suppress_until_ms = 0;
    r->hold_expired_at = -1;
    r->hold_armed_total = 0;
    r->client_gen_copy = 0;
    r->hold_last_release[0] = '\0';
    pthread_mutex_init(&r->lock, NULL);
    pthread_cond_init(&r->data_avail, NULL);
    pthread_cond_init(&r->writers_gone, NULL);
    /* 84-17: the writer's wait on space_avail has a deadline; a monotonic
     * condvar clock keeps it immune to wall-clock steps. */
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&r->space_avail, &ca);
    pthread_condattr_destroy(&ca);
}

/* 84-17: per-pa_stream_write context for _ring_push. One write call is
 * one wait budget: once the ceiling is hit the rest of THAT call is refused
 * at once (counted), so a stuck writer never serialises N batch timeouts. */
typedef struct {
    uint64_t        epoch;          /* g_ring.flush_epoch when the write began */
    int             have_deadline;
    int             expired;        /* ceiling hit: refuse the rest of this call */
    int             abandoned;      /* flush / teardown happened during the call */
    struct timespec deadline;       /* CLOCK_MONOTONIC */
    long            waited_ms;      /* time spent waiting for room */
    int64_t         refused;        /* bytes refused at the ceiling (counted in drops_total) */
    int64_t         abandoned_bytes;/* bytes dropped because of a flush (flushed_away) */
} ring_write_t;

#define RING_WRITE_WAIT_MAX_MS_DEFAULT 120000

/* Safety ceiling of a waiting writer. Default 120 s (longer than any
 * unread gap measured: 17.9 s for a 29 s tail); the harness shortens it
 * with SPOTON_FAKEPULSE_WRITE_WAIT_MS. */
static long _write_wait_max_ms(void) {
    const char *e = getenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
    if (e && *e) {
        long v = strtol(e, NULL, 10);
        if (v > 0 && v < 3600000) return v;
    }
    return RING_WRITE_WAIT_MAX_MS_DEFAULT;
}

static long _mono_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)(t.tv_sec * 1000L + t.tv_nsec / 1000000L);
}

/* 79-50 (D-34 R2): the decision window helpers. Atomics only, callable from the
 * flush caller thread and the HTTP thread. Elapsed times are wrap-safe
 * differences of _mono_ms() (a 32-bit long on armhf). */
static long _flush_decide_env_ms(void) {
    const char *e = getenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end != e && *end == '\0' && v >= 0 && v <= FLUSH_DECIDE_MS_MAX) {
            return v;
        }
    }
    return FLUSH_DECIDE_MS_DEFAULT;
}

static long _mono_since(long t0) {
    return (long)((unsigned long)_mono_ms() - (unsigned long)t0);
}

/* 1 iff a disconnect is pending AND its decision window has not run out. */
static int _flush_decide_open(void) {
    if (!g_flush_disconnect) {
        return 0;
    }
    long dl = atomic_load(&g_flush_decide_deadline);
    if (dl == 0) {
        return 0;
    }
    return (long)((unsigned long)dl - (unsigned long)_mono_ms()) > 0;
}

/* Ends the window whatever ended it: deadline, t0 and the promotion mark. */
static void _flush_decide_clear(void) {
    atomic_store(&g_flush_decide_deadline, 0);
    atomic_store(&g_flush_decide_t0, 0);
    atomic_store(&g_flush_decide_promoted, 0);
}

/* 79-37 D-31: the hold clock. 64-bit milliseconds of CLOCK_MONOTONIC; unlike
 * _mono_ms() (a 32-bit `long` on armhf that wraps after ~24.8 days and can
 * read negative) it cannot overflow, and no hold code tests a time value for
 * "valid" -- the validity flags do. Test builds add an offset so a cell can
 * force large negative readings. */
#ifdef FAKE_LIBPULSE_TEST
static _Atomic long long g_hold_test_clock_offset_ms = 0;
#endif
static int64_t _hold_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    int64_t v = (int64_t)t.tv_sec * 1000 + (int64_t)(t.tv_nsec / 1000000);
#ifdef FAKE_LIBPULSE_TEST
    v += (int64_t)atomic_load(&g_hold_test_clock_offset_ms);
#endif
    return v;
}

/* SPOTON_FAKEPULSE_HOLD_GAP_MS: 0 = hold off, 1..60000 the gap, anything else
 * (unset, invalid) the compiled default. SPOTON_FAKEPULSE_HOLD_MS: 1..5000,
 * anything else the compiled default. Only the writer-thread site (_ring_push)
 * calls these (the HTTP thread never calls getenv, see the vsink comment
 * below); the values are stored in the ring under the lock. */
static long _hold_gap_env_ms(void) {
    const char *e = getenv("SPOTON_FAKEPULSE_HOLD_GAP_MS");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end != e && *end == '\0') {
            if (v == 0) return 0;
            if (v >= 1 && v <= 60000) return v;
        }
    }
    return HOLD_GAP_MS_DEFAULT;
}

static long _hold_max_env_ms(void) {
    const char *e = getenv("SPOTON_FAKEPULSE_HOLD_MS");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end != e && *end == '\0' && v >= 1 && v <= 5000) return v;
    }
    return HOLD_MS_DEFAULT;
}

/* 84-20 (Q2): the virtual sink.
 *
 * Soloist connects its playback stream without a target length and decides
 * how much to write from pa_stream_writable_size(). Real PulseAudio answers
 * with the free part of a ~2 s buffer and drains it in real time; this shim
 * answered with the 20 s ring minus the reserve, and LMS pulls the ring
 * greedily, so the daemon ran far ahead of what was played (position, app
 * bar, and an uncork that waited for a fill that never came). The virtual
 * sink makes the shim answer like a sink of T ms: Q is the audio the sink
 * still "holds" (ring bytes, S32LE stereo -- S16 input counts in these
 * output bytes, F32 and S32 are the identity), it grows with every byte
 * written, drains at RING_BYTES_PER_SEC of wall-clock time while the stream
 * is UNcorked, and is emptied by a flush. writable_size, the underflow
 * decision and read_index/sink_usec all read this one Q, so they never
 * disagree. T 0 = off: every site behaves exactly as before.
 *
 * Locking: g_vsink is read and written ONLY while g_ring.lock is held, by the
 * daemon's thread and the HTTP thread alike, so (fill, Q) is always one
 * coherent pair. The one exception, the T in force, is only ever STORED by
 * the daemon-thread sites (they read the environment; the HTTP thread never
 * does, getenv is not thread-safe against a setenv) and read under the lock. */
#ifdef FAKE_LIBPULSE_TEST
/* Harness clock: non-zero = read instead of CLOCK_MONOTONIC. _Atomic: the test
 * thread writes it while the HTTP thread reads it. */
static _Atomic long long g_vsink_test_clock_us = 0;
#endif

typedef struct {
    int64_t   q_out;       /* ring bytes the sink holds */
    int64_t   frac;        /* sub-byte remainder of the drain (byte-microseconds) */
    long long last_us;     /* the instant q_out was last brought up to date */
    int       running;     /* 1 = uncorked: q_out drains */
    long      t_ms;        /* T in force (0 = off), stored by the daemon-thread sites */
    int64_t   suppressed;  /* underflow edges held back because q_out > 0 */
} vsink_t;

static vsink_t g_vsink;

static long long _vsink_now_us(void) {
#ifdef FAKE_LIBPULSE_TEST
    long long o = atomic_load(&g_vsink_test_clock_us);
    if (o != 0) return o;
#endif
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000LL + (long long)(t.tv_nsec / 1000);
}

/* T in ms: SPOTON_FAKEPULSE_VSINK_MS (0 off, 1..20000), anything else (unset,
 * invalid) the compiled default. env only -- no LMS preference (user decision
 * 2026-10-04). *src names where the value came from. */
static long _vsink_ms_src(const char **src) {
    const char *e = getenv("SPOTON_FAKEPULSE_VSINK_MS");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end != e && *end == '\0') {
            if (v == 0) {
                *src = "off";
                return 0;
            }
            if (v >= 1 && v <= 20000) {
                *src = "env";
                return v;
            }
        }
    }
    *src = "default";
    return VSINK_MS_DEFAULT;
}

static long _vsink_ms(void) {
    const char *src;
    return _vsink_ms_src(&src);
}

/* Brings q_out up to now (g_ring.lock held, t_ms > 0). */
static void _vsink_settle_locked(void) {
    long long now = _vsink_now_us();
    if (g_vsink.running && g_vsink.last_us > 0 && now > g_vsink.last_us && g_vsink.q_out > 0) {
        long long el = now - g_vsink.last_us;
        if (el > 100000000LL) el = 100000000LL;   /* >= any Q (max 20 s + a chunk) */
        long long num = el * RING_BYTES_PER_SEC + g_vsink.frac;
        int64_t d = num / 1000000LL;
        if (d >= g_vsink.q_out) {
            g_vsink.q_out = 0;
            g_vsink.frac = 0;
        } else {
            g_vsink.q_out -= d;
            g_vsink.frac = num % 1000000LL;
        }
    } else if (g_vsink.q_out == 0) {
        g_vsink.frac = 0;
    }
    g_vsink.last_us = now;
}

/* Every daemon-thread site calls this first (g_ring.lock held): stores the T
 * in force, restarts the sink on a change of T, settles under the current
 * running state. */
static void _vsink_sync_locked(long t_ms) {
    if (t_ms != g_vsink.t_ms) {
        g_vsink.t_ms = t_ms;
        g_vsink.q_out = 0;
        g_vsink.frac = 0;
        g_vsink.last_us = 0;
    }
    if (t_ms > 0) _vsink_settle_locked();
}

/* Empties the sink (flush, stream connect, teardown). g_ring.lock held. */
static void _vsink_reset_locked(void) {
    g_vsink.q_out = 0;
    g_vsink.frac = 0;
    g_vsink.last_us = g_vsink.t_ms > 0 ? _vsink_now_us() : 0;
}

/* Cork change / stream (dis)connect: from now on q_out drains or not; the
 * drain clock restarts here in BOTH directions, so a corked interval can
 * never be counted as drained once the stream runs. g_ring.lock held, after
 * _vsink_sync_locked (which settled under the OLD state). */
static void _vsink_set_running_locked(int running) {
    g_vsink.running = running;
    g_vsink.last_us = g_vsink.t_ms > 0 ? _vsink_now_us() : 0;
}

/* 79-37 D-31: the facts of one hold release, filled under the ring lock and
 * logged after it is released (no BOUNDARY line is written under the lock). */
typedef struct {
    int     active;       /* a hold was active when the release ran */
    int64_t at;
    int64_t held_ms;
    int64_t withheld;     /* bytes pushed since the hold armed (total_pushed - hold_at) */
    char    reason[16];
} hold_rel_t;

/* The ONE release path of the hold (g_ring.lock held). Also ends any empty
 * streak: a hold or an empty clock never outlives the situation it was
 * measured in. */
static void _hold_release_locked(ring_buffer_t *r, const char *reason, hold_rel_t *out) {
    out->active = (r->hold_at >= 0);
    out->at = r->hold_at;
    out->held_ms = 0;
    out->withheld = 0;
    snprintf(out->reason, sizeof(out->reason), "%s", reason);
    if (out->active) {
        out->held_ms = _hold_now_ms() - r->hold_since_ms;
        out->withheld = r->total_pushed - r->hold_at;
        snprintf(r->hold_last_release, sizeof(r->hold_last_release), "%s", reason);
        r->hold_at = -1;
    }
    r->empty_valid = 0;
}

static void _hold_log_release(const hold_rel_t *h) {
    if (h->active) {
        BOUNDARY("hold_released: reason=%s at=%lld held_ms=%lld withheld=%lld",
                 h->reason, (long long)h->at, (long long)h->held_ms, (long long)h->withheld);
    }
}

/* The ONE writer of g_ring.client_connected in the product code (the harness
 * pokes the field directly). A client change ends the hold and the empty
 * streak and forgets a timed-out hold of the previous client, so a hold never
 * outlives its client. `gen` is the HTTP thread's g_client_generation, stored
 * on an attach for the hold_armed log line (the writer thread must not read
 * the 64-bit generation unlocked). */
static void _ring_set_client(int connected, const char *reason, int64_t gen) {
    hold_rel_t h;
    pthread_mutex_lock(&g_ring.lock);
    g_ring.client_connected = connected;
    _hold_release_locked(&g_ring, reason, &h);
    g_ring.hold_expired_at = -1;
    if (connected) {
        g_ring.client_gen_copy = gen;
    }
    pthread_mutex_unlock(&g_ring.lock);
    _hold_log_release(&h);
}

/* 79-37 D-31: a hold that Control's POST did not confirm within HOLD_MS ends
 * (the held bytes are then served, none lost) and is remembered as
 * hold_expired_at so a late drain POST can say `hold=expired`. Runs once per
 * drain tick on the HTTP thread. */
static void _hold_timeout_check(void) {
    hold_rel_t h;
    h.active = 0;
    pthread_mutex_lock(&g_ring.lock);
    if (g_ring.hold_at >= 0
        && _hold_now_ms() - g_ring.hold_since_ms >= (int64_t)g_ring.hold_max_ms) {
        int64_t at = g_ring.hold_at;
        _hold_release_locked(&g_ring, "timeout", &h);
        g_ring.hold_expired_at = at;
    }
    pthread_mutex_unlock(&g_ring.lock);
    _hold_log_release(&h);
}

/* Push already-converted S32LE bytes into the ring.
 *
 * A full ring NEVER discards audio (user decision 2026-10-01, 84-17: "Nie
 * verwerfen, Daemon warten lassen"). The writer waits on space_avail --
 * the lock is released while it waits, so the pop path, writable_size, the
 * timing refresh, flush and the HTTP/control thread are never blocked by
 * it. Only the daemon's own writer thread waits, and only on an already
 * full ring (an unread gap, a long pause): in normal playback the daemon
 * self-throttles on writable_size and the ring never fills.
 *
 * The wait ends (a) when the consumer pops (room), (b) on a flush or a
 * stream teardown (flush_epoch changed: the rest of the chunk belongs to
 * the old title and is abandoned, counted in flushed_away), (c) at the
 * ceiling (_write_wait_max_ms): the bytes that found no room are refused,
 * counted in drops_total and logged by pa_stream_write -- never silent.
 *
 * History: 72879a60 removed an earlier blocking write because it held the
 * daemon's worker thread for the whole track and delayed its uncork; that
 * wait was UNCONDITIONAL on client_connected and the ring was 4 s. Here the
 * wait needs a truly full 20 s ring and is released by flush. */
static void _ring_push(ring_buffer_t *r, const unsigned char *data, size_t n, ring_write_t *w) {
    /* 79-37 D-31: facts for the BOUNDARY lines, written after the unlock. */
    int     hold_armed_now = 0, hold_skipped_now = 0;
    int64_t hold_armed_at = 0, hold_gap_seen = 0, hold_armed_gen = 0;
    pthread_mutex_lock(&r->lock);
    while (n > 0) {
        if (w && (w->abandoned || r->flush_epoch != w->epoch)) {
            w->abandoned = 1;
            w->abandoned_bytes += (int64_t)n;
            r->flushed_away += (int64_t)n;
            break;
        }
        if (r->fill == r->capacity) {
            if (!w || w->expired) {
                r->drops_total += (int64_t)n;  /* counted refusal, never silent */
                if (w) w->refused += (int64_t)n;
                break;
            }
            if (!w->have_deadline) {
                clock_gettime(CLOCK_MONOTONIC, &w->deadline);
                long ms = _write_wait_max_ms();
                w->deadline.tv_sec  += ms / 1000;
                w->deadline.tv_nsec += (ms % 1000) * 1000000L;
                if (w->deadline.tv_nsec >= 1000000000L) {
                    w->deadline.tv_sec++;
                    w->deadline.tv_nsec -= 1000000000L;
                }
                w->have_deadline = 1;
            }
            long t0 = _mono_ms();
            int rc = pthread_cond_timedwait(&r->space_avail, &r->lock, &w->deadline);
            w->waited_ms += _mono_ms() - t0;
            if (rc == ETIMEDOUT && r->fill == r->capacity && r->flush_epoch == w->epoch) {
                w->expired = 1;
            }
            continue;
        }

        size_t space = r->capacity - r->fill;
        size_t chunk = n < space ? n : space;
        size_t toEnd = r->capacity - r->head;
        size_t firstPart = chunk < toEnd ? chunk : toEnd;

        if (r->fill == 0) {
            /* 84-17: an empty ring is being refilled -- this is where the
             * previous content (a title's last byte, when the ring drained
             * before the next title's prebuffer) ended. */
            r->last_empty_pushed = r->total_pushed;

            /* 79-37 D-31: the gap hold. This writer-thread site reads the
             * knobs and stores them for the HTTP thread (getenv never runs
             * there). A refill after an empty streak of at least the gap,
             * with the client that emptied the ring still attached, is the
             * next title's burst after a natural end: hold it behind the old
             * title's last byte (hold_at = total_pushed BEFORE this chunk)
             * until Control's drain POST confirms the boundary. A fresh
             * client (empty_valid cleared at the attach), steady playback
             * (the ring is empty for tens of ms) and gap 0 never arm. */
            r->hold_gap_ms = _hold_gap_env_ms();
            r->hold_max_ms = _hold_max_env_ms();
            if (r->hold_gap_ms > 0 && r->client_connected && r->empty_valid
                && r->hold_at < 0) {
                int64_t now = _hold_now_ms();
                int64_t gap = now - r->empty_since_ms;
                if (gap >= (int64_t)r->hold_gap_ms) {
                    if (r->suppress_valid && now < r->hold_suppress_until_ms) {
                        r->suppress_valid = 0;   /* one-shot */
                        hold_skipped_now = 1;
                        hold_gap_seen = gap;
                    } else {
                        r->suppress_valid = 0;
                        r->hold_at = r->total_pushed;
                        r->hold_since_ms = now;
                        r->hold_armed_total++;
                        hold_armed_now = 1;
                        hold_armed_at = r->hold_at;
                        hold_gap_seen = gap;
                        hold_armed_gen = r->client_gen_copy;
                    }
                }
            }
        }

        memcpy(r->buf + r->head, data, firstPart);
        if (chunk > firstPart) {
            memcpy(r->buf, data + firstPart, chunk - firstPart);
        }

        r->head = (r->head + chunk) % r->capacity;
        r->fill += chunk;
        r->total_pushed += (int64_t)chunk;  /* Phase 77 Spike 2: monotonic write cursor */
        r->empty_valid = 0;                 /* 79-37 D-31: fresh data ends the empty streak */
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
    if (hold_armed_now) {
        BOUNDARY("hold_armed: at=%lld gap_ms=%lld gen=%lld",
                 (long long)hold_armed_at, (long long)hold_gap_seen, (long long)hold_armed_gen);
    }
    if (hold_skipped_now) {
        BOUNDARY("hold_skipped: reason=suppressed gap_ms=%lld", (long long)hold_gap_seen);
    }
}

/* 79-07 (84 WR-01): non-zero while THIS thread is inside pa_stream_write().
 * A teardown issued from inside the writer thread itself (a callback invoked
 * by pa_stream_write) must not wait for its own exit. */
static __thread int g_tls_in_write = 0;

/* 84-17 + 79-07 (84 WR-01): wake every waiting writer and make it abandon the
 * rest of its chunk (stream teardown; a flush does the same inside
 * _ring_flush), and do not return until
 * every writer has left pa_stream_write() -- waking a writer is not enough,
 * the woken thread still reads and writes the stream afterwards, so the
 * caller may only free the stream once this returns. The calling thread's
 * own write (if any) is not waited for. */
static void _ring_release_writers_and_wait(ring_buffer_t *r) {
    pthread_mutex_lock(&r->lock);
    r->flush_epoch++;
    pthread_cond_broadcast(&r->space_avail);
    while (r->writers_in - (g_tls_in_write ? 1 : 0) > 0) {
        pthread_cond_wait(&r->writers_gone, &r->lock);
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
    /* 79-50 (D-34 R2, E5): with a flush-disconnect pending (its decision window open,
     * or decided and not yet executed) no pop may take a byte, and like the hold cap
     * the check sits HERE, after the wait and under the lock: the drain loop usually
     * waits on data_avail with the gate in front of it already passed (the ring was
     * empty), the flush then raises the flag, and the first post-flush push wakes
     * that very pop -- the bytes of the next title would leave the ring for the old
     * client (C_off wrote=4096) or, with a keep, be lost for the kept one. */
    if (g_flush_disconnect) {
        pthread_mutex_unlock(&r->lock);
        return 0;
    }
    /* D-31 HOLD_CAP_BEGIN */
    /* 79-37: while a gap hold stands no pop may take a byte at or past the old
     * title's end. The cap sits HERE, after the wait and under the lock: the
     * drain loop usually waits on data_avail with pop_max already computed
     * from the empty ring, and the first post-gap push wakes that very pop. */
    if (r->hold_at >= 0) {
        int64_t room = r->hold_at - r->total_popped;
        if (room <= 0) {
            pthread_mutex_unlock(&r->lock);
            return 0;
        }
        if ((int64_t)maxlen > room) {
            maxlen = (size_t)room;
        }
    }
    /* D-31 HOLD_CAP_END */
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
        if (r->fill == 0 && r->client_connected) {
            /* 79-37 D-31: a pop that EMPTIED the ring starts the empty clock.
             * A pop that took nothing (timed-out wait, pop held by the cap)
             * never touches it -- the idle 50 ms ticks of a drained ring must
             * not restart the clock, or the gap would never reach HOLD_GAP_MS. */
            r->empty_valid = 1;
            r->empty_since_ms = _hold_now_ms();
        }
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
    r->last_empty_pushed = -1;  /* 84-17: a flush forgets the drained end of the old content */
    r->flush_epoch++;           /* 84-17: a writer waiting for room abandons its (old-title) chunk */
    pthread_cond_broadcast(&r->space_avail);  /* Phase 78: wake blocked producer after flush */
    /* soloist-browse-stutter fix: a flush starts a fresh empty streak for
     * the new track -- allow it to signal underflow_cb again once it
     * genuinely drains, same as any other empty transition.
     * WR-02 (77-REVIEW): moved inside the locked region (was after
     * unlock) -- this reset must serialize against the HTTP thread's
     * ring-empty-check-and-set in the drain loop, same reasoning as
     * _ring_push's own reset above. */
    g_ring_underrun_fired = 0;
    _vsink_reset_locked();      /* 84-20: a flush empties the virtual sink with the ring */
    /* 79-37 D-31: a flush (armed or not) ends the hold, the empty streak and a
     * remembered timed-out hold: the ring is empty because of the FLUSH, not a
     * pop, so the first post-flush push is served at once. */
    hold_rel_t hrel;
    _hold_release_locked(r, "flush", &hrel);
    r->hold_expired_at = -1;
    pthread_mutex_unlock(&r->lock);
    _hold_log_release(&hrel);
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
static void _convert_and_push(pa_sample_format_t fmt, const void *data, size_t nbytes, ring_write_t *w) {
    if (fmt == PA_SAMPLE_S32LE) {
        _ring_push(&g_ring, (const unsigned char *)data, nbytes, w);
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
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int32_t), w);
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
            _ring_push(&g_ring, (const unsigned char *)stackbuf, batch * sizeof(int32_t), w);
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
    /* WR-04 (77-REVIEW): captured at accept() time -- the control paths
     * (POST /seek-arm, POST /boundary) must only be honored from
     * loopback. The listen socket binds INADDR_ANY by design (players on
     * the LAN need to reach GET /stream), so without this check any LAN
     * peer could spam /seek-arm and, per WR-03, freeze that player's
     * audio until the TTL expires -- or spoof /boundary to force a
     * premature EOF. Perl only ever issues these two POSTs from
     * 127.0.0.1 (ProtocolHandler.pm, SoloistWS.pm), so restricting them
     * costs nothing. */
    int from_loopback;
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

/* debug connect-seek-stoppt-wiedergabe (2026-09-24): pending-slot and
 * control-request helpers, shared by _http_thread_fn's regular dispatch,
 * its accept block (preemption) and the flush-disconnect backlog pass
 * (_flush_backlog_pass below). All run on the HTTP thread only. */

/* One non-blocking read into the pending slot. EAGAIN/EWOULDBLOCK/EINTR
 * mean "head not there yet" (slot kept); EOF or any other error closes
 * and clears the slot. A slot whose head is already complete (or whose
 * bounded buffer is full) is left alone: nothing more is needed before
 * it is dispatched, and a loopback control POST is followed by the
 * peer's FIN (Control.pm _loopbackPost closes right after its one
 * syswrite) -- reading that EOF must not discard the request. */
static void _pending_try_read(pending_conn_t *p) {
    if (p->fd < 0 || _pending_head_complete(p) || p->len >= sizeof(p->buf) - 1) {
        return;
    }
    ssize_t n = read(p->fd, p->buf + p->len, sizeof(p->buf) - 1 - p->len);
    if (n > 0) {
        p->len += (size_t)n;
        p->buf[p->len] = '\0';
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        /* nothing yet -- keep the slot */
    } else {
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        p->buf[0] = '\0';
    }
}

/* A complete request head that is a POST naming `path` -- the same
 * strstr() classification the /boundary and /seek-arm dispatch always
 * used. */
static int _pending_is_control(const pending_conn_t *p, const char *path) {
    return p->fd >= 0 && _pending_head_complete(p)
        && strstr(p->buf, "POST") != NULL && strstr(p->buf, path) != NULL;
}

/* 84-17: true when `needle` occurs in the REQUEST LINE of the pending head
 * (before the first CRLF) -- the query string of `POST /boundary?anchor=drain`.
 * The headers are not searched: only the request line carries parameters. */
static int _head_line_has(const pending_conn_t *p, const char *needle) {
    const char *eol = strstr(p->buf, "\r\n");
    const char *hit = strstr(p->buf, needle);
    return hit != NULL && (eol == NULL || hit < eol);
}

/* Phase 77 Spike 2 (Bounded Endpoint Prototype): POST /boundary is a
 * control request, not a streaming client -- plant the marker and
 * respond WITHOUT running the GET /stream takeover logic, which would
 * otherwise close the currently-attached streaming client for what is
 * really just an out-of-band signal from SoloistWS.pm on WS
 * track_changed. Body moved verbatim out of _http_thread_fn (debug
 * connect-seek-stoppt-wiedergabe) so the accept block can also serve a
 * pending /boundary instead of preempting it unread. `client_fd` is the
 * HTTP thread's current streaming client (read-only here). */
static void _serve_boundary(pending_conn_t *p, int client_fd) {
    /* WR-04 (77-REVIEW): loopback-only. A spoofed /boundary from
     * any LAN peer would force a premature EOF on the currently
     * attached client -- refuse before touching any ring/arm
     * state. */
    if (!p->from_loopback) {
        static const char forbidden_resp[] =
            "HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)forbidden_resp,
                         sizeof(forbidden_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        return;
    }

    /* 84-17 (L1 repair): placement. A plain POST /boundary plants at the
     * ring's write position (total_pushed), exactly as before. The
     * connect-mode post carries `?anchor=drain`: a natural title end
     * leaves the ring EMPTY before the daemon pushes the next title's
     * prebuffer (1.5 s), so the old title ended where the empty ring was
     * last refilled (last_empty_pushed) -- planting at total_pushed would
     * lie that prebuffer inside the next title. Only a LIVE client (the
     * old title still being streamed = natural end) gets the drain
     * placement, only when that position lies within 2 s of the pushes
     * (else the ring did not drain at the end and the old placement is
     * the safe one), floored at what the client has already read
     * (total_popped: a boundary behind the read pointer is the same as
     * one at it -- the bounded serve closes on its next tick). Known
     * accepted race: an armed seek flush within 2 s of a natural end is
     * taken as the drain point (<= 2 s misattributed, the safe direction:
     * the old stream then ends early rather than late). */
    int want_drain = _head_line_has(p, "anchor=drain");
    /* 84-17 (found live in the skip regression): the daemon's skip flush has
     * raised g_flush_disconnect, but the disconnect only executes at the loop
     * top -- and since the stall fix this request can be served INSIDE a
     * stalled client write (_http_write_client), i.e. while the old client is
     * still attached and the disconnect still pending. A pending unarmed
     * flush-disconnect (an armed one cancelled it already) is the skip: the
     * old title is NOT being streamed to its natural end. Answer `departed`
     * and place no drain anchor -- the same as when the disconnect has already
     * run. Only the label and the anchor change; the planted marker and its
     * client generation are exactly what they were. */
    int flush_pending = (g_flush_disconnect && client_fd >= 0);
    if (flush_pending) {
        want_drain = 0;
    }
    /* 79-50 (D-34 R2): the skip. Control's /boundary (sent on track_changed) is
     * the signal that this flush was a title change, not a seek: the decision
     * window ends at once and the disconnect becomes final -- the loop top then
     * closes the old client at its next tick (reason=boundary), exactly as the
     * unarmed flush did before 79-50. Without the block the window would run
     * to its deadline. */
    /* D-34 R2_PROMOTE_BEGIN */
    if (flush_pending && _flush_decide_open()) {
        atomic_store(&g_flush_decide_promoted, 1);
        atomic_store(&g_flush_decide_deadline, 0);
    }
    /* D-34 R2_PROMOTE_END */
    pthread_mutex_lock(&g_ring.lock);
    int64_t pushed_now = g_ring.total_pushed;
    int64_t popped_now = g_ring.total_popped;
    int64_t last_empty = g_ring.last_empty_pushed;
    int64_t drops_now  = g_ring.drops_total;
    size_t ring_fill_now = g_ring.fill;
    int64_t planted = pushed_now;
    const char *anchor = "pushed";
    /* 79-37 D-31: the gap hold. With a hold standing, a drain request for a
     * live client plants EXACTLY at the old title's end (hold_at: nothing
     * beyond it was popped, the pop cap held it) and releases the hold. A
     * hold that timed out (this client's) is reported as `expired` with the
     * position it had; otherwise `none`. */
    const char *hold_state = "none";
    int64_t hold_report_at = -1;
    hold_rel_t hrel;
    hrel.active = 0;
    int hold_consumed_now = 0;
    if (g_ring.hold_at >= 0 && want_drain && client_fd >= 0) {
        hold_report_at = g_ring.hold_at;
        planted = g_ring.hold_at;
        anchor = "drain";
        _hold_release_locked(&g_ring, "boundary", &hrel);
        hold_state = "consumed";
        hold_consumed_now = 1;
    } else {
        if (g_ring.hold_at >= 0) {
            /* A POST that does not consume the hold (a plain /boundary: the
             * Connect session start, the skip/stop posts; or a drain request
             * with no live client) ends it at once and keeps today's
             * placement, so those callers never wait for the timeout. */
            hold_report_at = g_ring.hold_at;
            _hold_release_locked(&g_ring, "plain", &hrel);
            hold_state = "plain";
        } else if (g_ring.hold_expired_at >= 0) {
            hold_state = "expired";
            hold_report_at = g_ring.hold_expired_at;
            g_ring.hold_expired_at = -1;
        }
        if (want_drain && client_fd >= 0 && last_empty >= 0
            && pushed_now - last_empty <= (int64_t)2 * RING_BYTES_PER_SEC) {
            planted = last_empty;
            anchor = "drain";
            if (planted < popped_now) {
                planted = popped_now;
                anchor = "popped";
            }
        }
    }
    g_boundary_at_pushed = planted;
    pthread_mutex_unlock(&g_ring.lock);
    if (hold_consumed_now) {
        BOUNDARY("hold_consumed: at=%lld held_ms=%lld withheld=%lld",
                 (long long)hrel.at, (long long)hrel.held_ms, (long long)hrel.withheld);
    } else {
        _hold_log_release(&hrel);   /* plain release (hrel.active only then) */
    }
    /* boundary-trifft-nachfolgeclient fix, REOPENED (see
     * g_departed_client_generation's doc comment above
     * g_boundary_at_pushed for the full story): snapshot which
     * client generation this marker is FOR.
     *   - client_fd >= 0: a live predecessor -- use its real
     *     generation, as before.
     *   - client_fd < 0 but a client departed ABRUPTLY (write
     *     error, or closed by an unarmed flush-disconnect --
     *     debug connect-skip-prev-ton-bleibt) since the last
     *     time this was consumed: the
     *     marker is presumed to be for THAT departed client --
     *     inherit its generation and consume the record
     *     (one-shot) so it can't also attach to some later,
     *     unrelated plant.
     *   - client_fd < 0 and no departed generation on record:
     *     truly nobody, ever (D-04 rapid-skip shape) --
     *     NO_CLIENT_GENERATION, applies unconditionally to
     *     whoever attaches next. */
    const char *gen_via;
    if (client_fd >= 0) {
        g_boundary_client_generation = g_client_generation;
        gen_via = flush_pending ? "departed" : "live";
    } else if (g_departed_client_generation != NO_CLIENT_GENERATION) {
        g_boundary_client_generation = g_departed_client_generation;
        g_departed_client_generation = NO_CLIENT_GENERATION;
        gen_via = "departed";
    } else {
        g_boundary_client_generation = NO_CLIENT_GENERATION;
        gen_via = "none";
    }

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

    /* 84-17: the reply carries the shim's own classification -- the one
     * runtime fact that separates an app/LMS skip (`departed`: the old
     * client was already closed by the skip's flush-disconnect) from a
     * natural title end (`live`: the old title was still being streamed)
     * -- together with where the boundary was planted and the ring
     * counters. A text body with an exact Content-Length; Control.pm reads
     * it asynchronously, the old fire-and-forget callers never read it. */
    char reply_body[320];
    int reply_body_len = snprintf(reply_body, sizeof(reply_body),
        "via=%s boundary=%lld anchor=%s ring_fill=%zu total_pushed=%lld total_popped=%lld drops=%lld gen=%lld hold=%s hold_at=%lld\n",
        gen_via, (long long)planted, anchor, ring_fill_now,
        (long long)pushed_now, (long long)popped_now, (long long)drops_now,
        (long long)g_boundary_client_generation, hold_state, (long long)hold_report_at);
    if (reply_body_len < 0) {
        reply_body_len = 0;
        reply_body[0] = '\0';
    } else if ((size_t)reply_body_len >= sizeof(reply_body)) {
        reply_body_len = (int)sizeof(reply_body) - 1;
    }
    char reply_buf[512];
    int reply_len = snprintf(reply_buf, sizeof(reply_buf),
        "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        reply_body_len, reply_body);
    if (reply_len > 0 && (size_t)reply_len < sizeof(reply_buf)) {
        _http_write_all(p->fd, (const unsigned char *)reply_buf, (size_t)reply_len);
    }
    close(p->fd);
    p->fd = -1;
    p->len = 0;

    BOUNDARY("boundary_planted: total_pushed=%lld ring_fill=%zu gen=%lld via=%s anchor=%s seek_arm_reset hold=%s hold_at=%lld",
             (long long)g_boundary_at_pushed, ring_fill_now,
             (long long)g_boundary_client_generation, gen_via, anchor,
             hold_state, (long long)hold_report_at);
    BOUNDARY("boundary_reply: via=%s anchor=%s bytes=%d", gen_via, anchor, reply_len);
}

/* Phase 77 Task 2 (D-02/D-03, RESEARCH Pattern 1): POST /seek-arm is a
 * sibling control request to POST /boundary above -- same bounded
 * pending.buf/_pending_head_complete() parsing (T-77-02), same "respond
 * and return before the GET /stream takeover" shape so it can never
 * touch the streaming client. Parameterless bare trigger (RESEARCH V5 --
 * no body/query parsing, no new buffer or unbounded read path). Arms
 * (increments, saturating at SEEK_FLUSH_ARMED_MAX) the "next flush is a
 * same-track seek/mismatch reposition, not a skip" behavior consumed by
 * pa_stream_flush() below.
 *
 * debug connect-seek-stoppt-wiedergabe (2026-09-24): the ONE place that
 * decides whether an arm is consumed by a flush that already happened --
 * shared by every serving site (regular dispatch, pending-slot settle,
 * flush-disconnect backlog pass). That is the case when an UNARMED
 * pa_stream_flush() has already raised g_flush_disconnect, a client is
 * attached (`client_fd`, the HTTP thread's current streaming client) and
 * that disconnect has not executed yet. The arm then belongs to the flush
 * that already happened: Control.pm sends the arm strictly BEFORE the
 * WS command that makes Soloist flush (_armSync before $wireSend,
 * _loopbackPost's syswrite returns once the bytes sit in this socket's
 * receive queue), so an arm that is still queued here when the flush
 * lands was only read too late, not sent too late. It is consumed by
 * that flush -- g_flush_disconnect is cancelled and g_seek_flush_armed
 * is NOT incremented (an increment would arm the NEXT flush and, via
 * the drain gate, withhold audio from the kept client until the 3 s
 * TTL). Returns 1 iff the arm cancelled a pending flush-disconnect. */
static int _serve_seek_arm(pending_conn_t *p, int client_fd, const char *via) {
    /* WR-04 (77-REVIEW): loopback-only -- see _serve_boundary. Because
     * of WR-03's TTL, a spoofed /seek-arm now only freezes the attached
     * client's audio for up to SEEK_ARM_TTL_MS rather than
     * indefinitely, but there is still no reason to accept it from a
     * non-loopback peer at all -- nor to let one cancel a disconnect. */
    if (!p->from_loopback) {
        static const char forbidden_resp[] =
            "HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)forbidden_resp,
                         sizeof(forbidden_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        return 0;
    }

    static const char seek_arm_resp[] =
        "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    if (g_flush_disconnect && client_fd >= 0) {
        g_flush_disconnect = 0;
        _flush_decide_clear();   /* 79-50 (W4): a late arm ends the decision window too */
        _http_write_all(p->fd, (const unsigned char *)seek_arm_resp,
                         sizeof(seek_arm_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        if (g_debug_trace) {
            char _ts[32];
            _trace_ts(_ts, sizeof(_ts));
            fprintf(stderr, "[fakepulse %s] flush-disconnect cancelled by queued seek-arm (via=%s)\n", _ts, via);
        }
        BOUNDARY("seek_arm: consumed by pending flush-disconnect via=%s armed=%d",
                 via, (int)g_seek_flush_armed);
        return 1;
    }

    /* WR-01 (77-REVIEW): CAS loop for symmetry with the consuming
     * decrement in pa_stream_flush() -- the same read-modify-write
     * shape (saturating increment) is subject to the same
     * cross-thread TOCTOU if this ever races a concurrent decrement
     * or reset, even though today this call site only runs on the
     * HTTP thread (belt-and-suspenders, not a currently-observed
     * bug). */
    int arm_expected = atomic_load(&g_seek_flush_armed);
    while (arm_expected < SEEK_FLUSH_ARMED_MAX
           && !atomic_compare_exchange_weak(&g_seek_flush_armed, &arm_expected, arm_expected + 1)) {
        /* arm_expected reloaded by the failed CAS; retry until we
         * increment or observe the cap has already been reached. */
    }
    /* WR-03 (77-REVIEW): stamp the wall-clock time of this arm so
     * the drain loop can expire it if the expected flush never
     * arrives (see g_seek_arm_at's doc comment above). Always
     * refreshed on every /seek-arm, including the saturated-no-op
     * case -- a fresh arm request means the most recent seek is
     * the one whose TTL matters. */
    gettimeofday(&g_seek_arm_at, NULL);

    _http_write_all(p->fd, (const unsigned char *)seek_arm_resp,
                     sizeof(seek_arm_resp) - 1);
    close(p->fd);
    p->fd = -1;
    p->len = 0;

    BOUNDARY("seek_arm: armed=%d", (int)g_seek_flush_armed);
    return 0;
}

/* 79-37 D-31: POST /hold-release is a sibling control request of /boundary and
 * /seek-arm -- served and answered WITHOUT the GET /stream takeover, so it
 * never touches client_fd. Control posts it when playback resumes without a
 * track change (a pause longer than the hold gap leaves the ring empty, and
 * the resume would otherwise be held for up to HOLD_MS). With a hold standing
 * it releases it at once (`hold=released`); with none standing it suppresses
 * the next arming for one hold time (`hold=suppressed`), so the resume is not
 * held whichever of the post and the daemon's first push arrives first.
 *
 * LOOPBACK-ONLY: the listener binds INADDR_ANY, so the guard is the first
 * statement and answers 403 before any state is read or written. */
static void _serve_hold_release(pending_conn_t *p) {
    if (!p->from_loopback) {
        static const char forbidden_resp[] =
            "HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)forbidden_resp,
                         sizeof(forbidden_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        return;
    }
    hold_rel_t h;
    char body[200];
    long window = 0;
    int released = 0;
    pthread_mutex_lock(&g_ring.lock);
    window = g_ring.hold_max_ms;
    if (g_ring.hold_at >= 0) {
        _hold_release_locked(&g_ring, "release", &h);
        released = 1;
        snprintf(body, sizeof(body), "hold=released at=%lld held_ms=%lld withheld=%lld\n",
                 (long long)h.at, (long long)h.held_ms, (long long)h.withheld);
    } else {
        h.active = 0;
        g_ring.suppress_valid = 1;
        g_ring.hold_suppress_until_ms = _hold_now_ms() + (int64_t)window;
        snprintf(body, sizeof(body), "hold=suppressed window_ms=%ld\n", window);
    }
    pthread_mutex_unlock(&g_ring.lock);
    char reply[320];
    int reply_len = snprintf(reply, sizeof(reply),
        "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        (int)strlen(body), body);
    if (reply_len > 0 && (size_t)reply_len < sizeof(reply)) {
        _http_write_all(p->fd, (const unsigned char *)reply, (size_t)reply_len);
    }
    close(p->fd);
    p->fd = -1;
    p->len = 0;
    if (released) {
        _hold_log_release(&h);
    } else {
        BOUNDARY("hold_suppressed: window_ms=%ld", window);
    }
}

/* 79-47 (D-34): POST /browse-keep?on=1|0 sets or clears g_browse_keep (see
 * its doc comment). A sibling control request of /seek-arm and /hold-release:
 * served and answered WITHOUT the GET /stream takeover, never touches
 * client_fd. LOOPBACK-ONLY (403 before any state is read or written, the
 * listener binds INADDR_ANY). A request without on=1 or on=0 in its request
 * line answers 400 and changes nothing. The reply body is the state after
 * the request: `browse_keep=<0|1>`. */
static void _serve_browse_keep(pending_conn_t *p) {
    if (!p->from_loopback) {
        static const char forbidden_resp[] =
            "HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)forbidden_resp,
                         sizeof(forbidden_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        return;
    }
    int want = -1;
    if (_head_line_has(p, "on=1")) {
        want = 1;
    } else if (_head_line_has(p, "on=0")) {
        want = 0;
    }
    if (want < 0) {
        static const char bad_resp[] =
            "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)bad_resp, sizeof(bad_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        BOUNDARY("browse_keep: refused (no on=0|1) keep=%d", (int)atomic_load(&g_browse_keep));
        return;
    }
    int was = atomic_exchange(&g_browse_keep, want);
    char body[32];
    snprintf(body, sizeof(body), "browse_keep=%d\n", want);
    char reply[160];
    int reply_len = snprintf(reply, sizeof(reply),
        "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        (int)strlen(body), body);
    if (reply_len > 0 && (size_t)reply_len < sizeof(reply)) {
        _http_write_all(p->fd, (const unsigned char *)reply, (size_t)reply_len);
    }
    close(p->fd);
    p->fd = -1;
    p->len = 0;
    if (g_debug_trace) {
        char _ts[32];
        _trace_ts(_ts, sizeof(_ts));
        fprintf(stderr, "[fakepulse %s] browse-keep: %d -> %d\n", _ts, was, want);
    }
    BOUNDARY("browse_keep: %d -> %d", was, want);
}

/* 79-50 (D-34 R2): POST /seek-keep keeps the client of an unarmed flush whose
 * decision window is open (see g_flush_decide_deadline's doc comment). Control
 * sends it when the daemon's first frame after the flush is a `buffering`
 * playback_state for the title it already observed (an app seek or restart),
 * 6-7 ms after the flush (E1). A sibling control request of /seek-arm and
 * /browse-keep: served and answered WITHOUT the GET /stream takeover, parameterless
 * (no body or query parsing), LOOPBACK-ONLY (403 before any state is read, the
 * listener binds INADDR_ANY). Keep case: a disconnect is pending, a client is
 * attached and the decision is still open -> clear g_flush_disconnect and the
 * deadline, reply `seek_keep=1`. Anything else (nothing pending, a decision that
 * is already final: /boundary came first, the deadline ran out) -> reply
 * `seek_keep=0` and change nothing. It never touches g_seek_flush_armed or
 * g_browse_keep, so it can never arm the drain gate. `client_fd` is the HTTP
 * thread's current streaming client (read-only here). */
static void _serve_seek_keep(pending_conn_t *p, int client_fd) {
    if (!p->from_loopback) {
        static const char forbidden_resp[] =
            "HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _http_write_all(p->fd, (const unsigned char *)forbidden_resp,
                         sizeof(forbidden_resp) - 1);
        close(p->fd);
        p->fd = -1;
        p->len = 0;
        return;
    }
    int kept = 0;
    long after_ms = 0;
    int pending_now = (g_flush_disconnect && client_fd >= 0);
    if (pending_now && _flush_decide_open()) {
        long t0 = atomic_load(&g_flush_decide_t0);
        after_ms = (t0 != 0) ? _mono_since(t0) : 0;
        g_flush_disconnect = 0;
        _flush_decide_clear();
        kept = 1;
    }
    char body[32];
    snprintf(body, sizeof(body), "seek_keep=%d\n", kept);
    char reply[160];
    int reply_len = snprintf(reply, sizeof(reply),
        "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        (int)strlen(body), body);
    if (reply_len > 0 && (size_t)reply_len < sizeof(reply)) {
        _http_write_all(p->fd, (const unsigned char *)reply, (size_t)reply_len);
    }
    close(p->fd);
    p->fd = -1;
    p->len = 0;
    if (g_debug_trace) {
        char _ts[32];
        _trace_ts(_ts, sizeof(_ts));
        if (kept) {
            fprintf(stderr, "[fakepulse %s] seek-keep: kept active HTTP client after_ms=%ld\n", _ts, after_ms);
        } else {
            fprintf(stderr, "[fakepulse %s] seek-keep: nothing pending\n", _ts);
        }
    }
    if (kept) {
        BOUNDARY("seek_keep: kept after_ms=%ld", after_ms);
    } else {
        BOUNDARY("seek_keep: noop reason=%s", pending_now ? "decided" : "none");
    }
}

/* Serves the request in `p` if it is a complete control request; returns 1 if
 * it was one (served and closed), 0 otherwise (a stream request or an unread
 * head: untouched). The one classification the settle, the in-place newcomer
 * rule and the write loop share. */
static int _pending_serve_control(pending_conn_t *p, int client_fd, const char *via) {
    if (_pending_is_control(p, "/boundary")) {
        _serve_boundary(p, client_fd);
        return 1;
    }
    if (_pending_is_control(p, "/seek-arm")) {
        _serve_seek_arm(p, client_fd, via);
        return 1;
    }
    if (_pending_is_control(p, "/hold-release")) {
        _serve_hold_release(p);
        return 1;
    }
    if (_pending_is_control(p, "/browse-keep")) {
        _serve_browse_keep(p);
        return 1;
    }
    if (_pending_is_control(p, "/seek-keep")) {
        _serve_seek_keep(p, client_fd);
        return 1;
    }
    return 0;
}

/* The single pending slot is about to be taken by a newer connection.
 * Finish reading its current occupant first and serve it if it turns
 * out to be a complete control request; preempt (close) it only
 * otherwise. The newest-unconfirmed-connection-wins rule is meant for
 * stream requests -- before this, a control POST that simply had not
 * been read yet (accept and read happen in different ticks) was closed
 * unread by the next GET (82-16 todo, 82-G1 Vorbefund: 6/6 async arms
 * lost this way). */
static void _pending_settle(pending_conn_t *p, int client_fd, const char *via) {
    _pending_try_read(p);
    if (p->fd < 0) {
        return;
    }
    if (_pending_serve_control(p, client_fd, via)) {
        return;
    }
    /* A newer connection preempts a still-unconfirmed pending stream
     * request -- does NOT touch the active client. */
    close(p->fd);
    p->fd = -1;
    p->len = 0;
}

/* Accepts one queued connection into the pending slot (settling any
 * current occupant first, see _pending_settle). Returns 1 if a
 * connection was accepted. */
static int _pending_accept(pending_conn_t *p, int client_fd, const char *via) {
    /* WR-04 (77-REVIEW): capture the peer address at accept() so
     * the control-path handlers can refuse non-loopback callers. */
    struct sockaddr_in peer_addr;
    socklen_t peer_len = sizeof(peer_addr);
    int newfd = accept(g_http_listen_fd, (struct sockaddr *)&peer_addr, &peer_len);
    if (newfd < 0) {
        return 0;
    }
    int from_loopback =
        (peer_len >= (socklen_t)sizeof(peer_addr))
        && (peer_addr.sin_family == AF_INET)
        && (peer_addr.sin_addr.s_addr == htonl(INADDR_LOOPBACK));
    if (p->fd >= 0) {
        /* 79-50 (D-34 R2, B1): a control newcomer never costs a waiting stream
         * request. Any loopback POST -- /seek-keep above all, which is frame-driven
         * and so not ordered against LMS's GET the way the arm is -- used to settle
         * (and, for a stream occupant, CLOSE) the slot's GET /stream: LMS's own seek
         * restart (ProtocolHandler.pm:1026-1034, a new GET 10-15 ms before the keep)
         * would die and the player stop. So the NEWCOMER is read first (non-blocking,
         * at most 5 ms for its head); a complete control request is served in place
         * and the occupant stays untouched, including its read state. An earlier
         * control request still waiting in the slot is served first, so the order of
         * control requests never changes. Anything else settles the occupant exactly
         * as before and the newcomer, with the bytes already read, takes the slot. */
        pending_conn_t nc;
        nc.fd = newfd;
        nc.len = 0;
        nc.buf[0] = '\0';
        nc.from_loopback = from_loopback;
        gettimeofday(&nc.started, NULL);
        _set_nonblocking(newfd);
        struct pollfd nfd;
        nfd.fd = newfd;
        nfd.events = POLLIN;
        nfd.revents = 0;
        (void)poll(&nfd, 1, 5);
        _pending_try_read(&nc);
        if (nc.fd < 0) {
            return 1;    /* the newcomer went away before sending a head: the occupant is untouched */
        }
        if (_pending_is_control(&nc, "/boundary") || _pending_is_control(&nc, "/seek-arm")
            || _pending_is_control(&nc, "/hold-release") || _pending_is_control(&nc, "/browse-keep")
            || _pending_is_control(&nc, "/seek-keep")) {
            _pending_try_read(p);
            if (p->fd >= 0 && _pending_serve_control(p, client_fd, via)) {
                /* the earlier control request is served first */
            }
            (void)_pending_serve_control(&nc, client_fd, via);
            return 1;
        }
        _pending_settle(p, client_fd, via);
        p->fd = nc.fd;
        p->len = nc.len;
        memcpy(p->buf, nc.buf, nc.len + 1);
        p->from_loopback = nc.from_loopback;
        p->started = nc.started;
        return 1;
    }
    _set_nonblocking(newfd);
    p->fd = newfd;
    p->len = 0;
    p->buf[0] = '\0';    /* clear stale bytes from a prior
                            pending connection -- without
                            this, a leftover "\r\n\r\n" tail
                            in the buffer makes
                            _pending_head_complete() return
                            true for a brand-new connection
                            that hasn't sent a single byte */
    p->from_loopback = from_loopback;
    gettimeofday(&p->started, NULL);
    return 1;
}

/* debug connect-seek-stoppt-wiedergabe (2026-09-24): the flush-disconnect
 * backlog pass. Runs at the loop top when an unarmed pa_stream_flush()
 * has raised g_flush_disconnect and a client is attached -- BEFORE that
 * client is closed. It services every connection that is already queued
 * for this thread, without blocking: first the pending slot (accepted in
 * an earlier tick, possibly unread), then up to FLUSH_BACKLOG_PASS_MAX
 * connections from the listen backlog (poll 0 + accept + one
 * non-blocking read each). A loopback POST /seek-arm found there is
 * consumed by the flush that already happened and cancels the
 * disconnect (see _serve_seek_arm); a GET or /boundary becomes the
 * pending occupant exactly as the regular accept block would make it.
 *
 * Why here: the HTTP thread sleeps up to 50 ms in _ring_pop_timed()
 * whenever the ring is empty (proxy-mode LMS drains greedily, so it
 * usually is), and a new connection is accepted in one loop tick and
 * read only in the next, with this flush-disconnect check at the top of
 * each. Measured live (lavender-UAT, 2026-09-24 07:04:57, 08:04:14,
 * 08:07:22): LMS sent the arm 2-6 ms before Soloist's flush, the flush
 * was decided unarmed, the disconnect closed LMS' FRESH proxy seek
 * stream, and `seek_arm: armed=1` followed 4-50 ms later (leaking into
 * the drain gate for the 3 s TTL). The arm's bytes are in the kernel
 * before the WS seek is even sent, so this pass sees them by
 * construction.
 *
 * Accepted residual (recoverable direction): an arm meant for a LATER
 * command that lands inside the window between an app-side skip's
 * unarmed flush and this pass cancels that skip's disconnect -- the
 * attached client keeps streaming the new track without an EOF, and the
 * flush the arm was meant for then runs unarmed and disconnects, so LMS
 * restarts that stream. A lost stream (the defect) is not recoverable
 * without the user; a restarted stream is. */
#define FLUSH_BACKLOG_PASS_MAX 8
static void _flush_backlog_pass(pending_conn_t *p, int client_fd) {
    _pending_try_read(p);
    if (_pending_is_control(p, "/seek-arm")) {
        _serve_seek_arm(p, client_fd, "pending");
    } else if (_pending_is_control(p, "/seek-keep")) {
        _serve_seek_keep(p, client_fd);    /* 79-50: the keep of the decision window, served wherever the arm is */
    }
    for (int i = 0; i < FLUSH_BACKLOG_PASS_MAX && g_flush_disconnect; i++) {
        struct pollfd lfd;
        lfd.fd = g_http_listen_fd;
        lfd.events = POLLIN;
        lfd.revents = 0;
        if (poll(&lfd, 1, 0) <= 0 || !(lfd.revents & POLLIN)) {
            break;
        }
        if (!_pending_accept(p, client_fd, "backlog")) {
            break;
        }
        _pending_try_read(p);
        if (_pending_is_control(p, "/seek-arm")) {
            _serve_seek_arm(p, client_fd, "backlog");
        } else if (_pending_is_control(p, "/seek-keep")) {
            _serve_seek_keep(p, client_fd);
        }
    }
}

/* 84-17 (found live in the long-tail proof, 2026-10-01 11:21:19): write to the
 * STREAMING client without blocking the control endpoints. The HTTP thread
 * serves POST /boundary and /seek-arm AND feeds the client. _http_write_all
 * waits up to 2 s for POLLOUT, and a proxy-mode LMS whose player buffers hold
 * a long tail (12-37 s) stops reading the socket: a control POST sent right
 * then waited for the stalled write (304 ms live, past Control's 0.3 s reply
 * cap -- the change took the immediate path and cut the 32 s tail), and was
 * finally classified `departed` because the stalled client had closed in the
 * meantime. Here every wait is a 20 ms poll() over the client's POLLOUT AND the
 * listen socket: a connection that arrives meanwhile is accepted into the
 * (empty) pending slot, and a complete control request in it is served in
 * place (_serve_boundary / _serve_seek_arm only READ client_fd; they never
 * touch the chunk being written).
 *
 * 84-22 (F-20-WRITER, todo fake-libpulse-writer-bricht-nach-langer-pause-ab):
 * the 84-17 version also kept the old 2 s no-progress bound (the former
 * HTTP_WRITE_STALL_MS define, removed here) and answered -1 "client gone" at
 * its end. A player that stops reading for ~15 s -- a SIGSTOPped squeezelite
 * closed 12.05 / 12.58 s after the stop in the two HEAD live archives (the 2 s
 * bound plus ~10 s of buffers filling) -- lost its stream and LMS stopped ~27 s
 * after the resume. A stalled reader is NOT a departed one. Return codes:
 *    0  every byte written
 *   -1  the client really went away: POLLERR/POLLHUP/POLLNVAL or a hard write
 *       error (EPIPE/ECONNRESET) -- the caller records it as departed
 *    2  a flush is pending (g_flush_disconnect): the chunk is abandoned, the
 *       caller leaves WITHOUT marking anything departed and the next iteration's
 *       loop top runs the existing flush path (backlog pass, close, record)
 *    3  a request head that is not a control request sits complete in the
 *       pending slot (GET /stream = a takeover): same hand-off, the existing
 *       takeover code of the main loop closes the old client and serves it
 *    4  orphan bound: no progress for HTTP_WRITE_ORPHAN_MS with none of the
 *       above -- treated exactly like -1 (departed generation recorded), with
 *       its own trace literal. The bound counts NO-PROGRESS time, which only
 *       starts once the socket/LMS/player buffers are full, not the stall length.
 * A connection in the pending slot that never completes its head is expired
 * here after HTTP_REQUEST_TIMEOUT_MS: with the 2 s write bound gone the main
 * loop (which used to expire it every time the write gave up) would otherwise
 * not run for the whole stall, and the occupied slot refuses every new
 * connection -- control POSTs included. */
#define HTTP_WRITE_TICK_MS      20
#define HTTP_WRITE_ORPHAN_MS    180000  /* user decision at 84-22 checkpoint 2a ("180 s"; the 60 s / 90 s stall runs did not settle it: LMS's own 15 s heartbeat drops the player first); ONE define, echoed in the trace line */

/* Orphan bound: the define, overridable through SPOTON_FAKEPULSE_WRITE_ORPHAN_MS
 * (harness, ops). Read per client write like _write_wait_max_ms() reads
 * SPOTON_FAKEPULSE_WRITE_WAIT_MS: the harness sets it AFTER the constructor ran,
 * and the write holds no lock a setenv could race on. */
static long _write_orphan_ms(void) {
    const char *e = getenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS");
    if (e && *e) {
        long v = strtol(e, NULL, 10);
        if (v > 0 && v < 3600000) {
            return v;
        }
    }
    return HTTP_WRITE_ORPHAN_MS;
}

static int _http_write_client(int client_fd, const unsigned char *data, size_t n, pending_conn_t *pending, long *no_progress_ms) {
    size_t off = 0;
    struct timeval progress_at;
    const long orphan_ms = _write_orphan_ms();
    gettimeofday(&progress_at, NULL);
    while (off < n) {
        struct pollfd fds[2];
        int nf = 1;
        int lidx = -1;
        fds[0].fd = client_fd;
        fds[0].events = POLLOUT;
        fds[0].revents = 0;
        fds[1].revents = 0;
        if (pending->fd < 0) {
            fds[1].fd = g_http_listen_fd;
            fds[1].events = POLLIN;
            lidx = 1;
            nf = 2;
        }
        int rc = poll(fds, nf, HTTP_WRITE_TICK_MS);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            return -1;
        }
        if (fds[0].revents & POLLOUT) {
            ssize_t w = write(client_fd, data + off, n - off);
            if (w < 0) {
                if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    return -1;
                }
            } else if (w > 0) {
                off += (size_t)w;
                gettimeofday(&progress_at, NULL);
            }
        }
        if (lidx >= 0 && (fds[lidx].revents & POLLIN)) {
            _pending_accept(pending, client_fd, "write-wait");
        }
        if (pending->fd >= 0) {
            _pending_try_read(pending);
            if (_pending_is_control(pending, "/boundary")) {
                _serve_boundary(pending, client_fd);
            } else if (_pending_is_control(pending, "/seek-arm")) {
                _serve_seek_arm(pending, client_fd, "write-wait");
            } else if (_pending_is_control(pending, "/hold-release")) {
                _serve_hold_release(pending);
            } else if (_pending_is_control(pending, "/browse-keep")) {
                _serve_browse_keep(pending);
            } else if (_pending_is_control(pending, "/seek-keep")) {
                _serve_seek_keep(pending, client_fd);    /* 79-50 D-34 R2 */
            }
        }
        if (pending->fd >= 0 && !_pending_head_complete(pending)
            && _elapsed_ms(&pending->started) >= HTTP_REQUEST_TIMEOUT_MS) {
            close(pending->fd);
            pending->fd = -1;
            pending->len = 0;
            pending->buf[0] = '\0';
        }
        if (off < n) {
            /* the control requests above ran first: a seek-arm that arrived
             * with the flush consumes it (_serve_seek_arm), and only a flush
             * that is still pending ends the write */
            /* 79-50 (D-34 R2, C7): while the decision window is open the chunk in
             * flight is completed, never cut -- 2 only once the decision is final
             * (the keep clears the flag, the boundary or the deadline ends it) */
            if (g_flush_disconnect && !_flush_decide_open()) {
                return 2;
            }
            if (pending->fd >= 0
                && (_pending_head_complete(pending) || pending->len >= sizeof(pending->buf) - 1)) {
                return 3;
            }
            long idle = _elapsed_ms(&progress_at);
            if (idle >= orphan_ms) {
                if (no_progress_ms) {
                    *no_progress_ms = idle;
                }
                return 4;
            }
        }
    }
    return 0;
}

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
         * WR-11 takeover semantics still apply to it normally.
         *
         * debug connect-seek-stoppt-wiedergabe: service the already-queued
         * connections FIRST -- a POST /seek-arm among them was sent before
         * the flush and cancels this disconnect (see _flush_backlog_pass). */
        if (g_flush_disconnect && client_fd >= 0) {
            _flush_backlog_pass(&pending, client_fd);
        }
        /* 79-50 (D-34 R2): the decision is final unless a window is open (an
         * unarmed flush holds its disconnect for FLUSH_DECIDE_MS so Control's
         * /seek-keep can arrive, see g_flush_decide_deadline). While it is open the
         * backlog pass above still runs and serves a queued /seek-keep, /seek-arm
         * or /boundary. Cutting the marked block restores the immediate close. */
        int decide_open = 0;
        /* D-34 R2_DEFER_BEGIN */
        decide_open = (g_flush_disconnect && client_fd >= 0) ? _flush_decide_open() : 0;
        /* D-34 R2_DEFER_END */
        if (g_flush_disconnect && client_fd >= 0 && !decide_open) {
            long decide_t0 = atomic_load(&g_flush_decide_t0);
            if (decide_t0 != 0) {
                /* the window ran its course: the first of /boundary and the deadline decided */
                const char *why = atomic_load(&g_flush_decide_promoted) ? "boundary" : "deadline";
                long after = _mono_since(decide_t0);
                if (g_debug_trace) {
                    char _ts[32];
                    _trace_ts(_ts, sizeof(_ts));
                    fprintf(stderr, "[fakepulse %s] flush-decide: closed reason=%s after_ms=%ld\n", _ts, why, after);
                }
                BOUNDARY("flush_decide: closed reason=%s after_ms=%ld", why, after);
            }
            _flush_decide_clear();
            close(client_fd);
            client_fd = -1;
            _ring_set_client(0, "disconnect", 0);   /* 79-37 D-31 (the flush itself released the hold as "flush") */
            g_flush_disconnect = 0;
            g_awaiting_first_drain = 1;   /* 76-07: arm the t4 (first-drain) stamp */
            /* Phase 77 Spike 2: an app-side skip flushes the ring (see
             * pa_stream_flush below), which invalidates any bytes a
             * previously-planted boundary marker was counting toward --
             * drop it so a stale marker can't spuriously close whatever
             * client reconnects next. */
            g_boundary_at_pushed = -1;
            /* debug connect-skip-prev-ton-bleibt (2026-09-24, decision
             * 2A): RECORD the closed client as departed. The wipe just
             * above only covers a marker planted BEFORE this close; the
             * skip's own POST /boundary is sent on WS track_changed, which
             * FOLLOWS the flush -- measured 12:01:37 and 12:10:00: planted
             * after this close with no client attached, it used to get
             * NO_CLIENT_GENERATION (this line cleared the record) and was
             * inherited by LMS' fresh stream for the next title, closed
             * after 16384 bytes -> STOPPED. With the record, that plant
             * takes this client's generation (via=departed) and the next
             * attach makes it stale (boundary_discarded). One-shot and
             * cleared on every attach, exactly like the write-error
             * record -- see g_departed_client_generation's doc comment
             * above g_boundary_at_pushed. */
            g_departed_client_generation = g_client_generation;
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
            /* A still-occupied pending slot is settled (read, and served
             * if it is a control request) before the new connection takes
             * it -- see _pending_settle. */
            _pending_accept(&pending, client_fd, "preempt");
        }

        /* debug connect-seek-stoppt-wiedergabe: a head that is already
         * complete (read by _pending_settle/_flush_backlog_pass) needs no
         * further read -- and must not get one: after a loopback control
         * POST the next read returns the peer's EOF, which would close
         * the request before it is dispatched below. */
        if (pending.fd >= 0 && pending_idx >= 0 && rc > 0
            && !_pending_head_complete(&pending)
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

        /* Control requests (POST /boundary, POST /seek-arm) are served
         * and answered WITHOUT running the GET /stream takeover below, so
         * they can never touch client_fd -- bodies in _serve_boundary /
         * _serve_seek_arm (moved there so the accept block and the
         * flush-disconnect backlog pass share the one implementation). */
        if (_pending_is_control(&pending, "/boundary")) {
            _serve_boundary(&pending, client_fd);
            continue; /* back to the top of the for(;;) -- skip GET /stream takeover */
        }

        if (_pending_is_control(&pending, "/seek-arm")) {
            /* debug connect-seek-stoppt-wiedergabe: if an unarmed flush
             * landed after this tick's loop-top check (g_flush_disconnect
             * raised for the attached client), _serve_seek_arm lets this
             * arm consume it -- the same rule _flush_backlog_pass applies
             * at the next loop top. */
            _serve_seek_arm(&pending, client_fd, "handler");
            continue; /* back to the top of the for(;;) -- skip GET /stream takeover */
        }

        if (_pending_is_control(&pending, "/hold-release")) {
            /* 79-37 D-31: served like the two above, never a stream takeover. */
            _serve_hold_release(&pending);
            continue;
        }

        if (_pending_is_control(&pending, "/browse-keep")) {
            /* 79-47 D-34: served like the three above, never a stream takeover. */
            _serve_browse_keep(&pending);
            continue;
        }

        if (_pending_is_control(&pending, "/seek-keep")) {
            /* 79-50 D-34 R2: the keep of the decision window, never a stream takeover. */
            _serve_seek_keep(&pending, client_fd);
            continue;
        }

        if (pending.fd >= 0
            && (_pending_head_complete(&pending) || pending.len >= sizeof(pending.buf) - 1))
        {
            /* Full request head arrived (or the bounded buffer filled,
             * matching the old discard function's give-up-parsing
             * behavior) -- NOW take over. */
            /* 79-50 (D-34 R2, M1): captured BEFORE the close below (it used to be read
             * after `client_fd = -1`, so it was always 0 and the clear further down
             * ran on every takeover; the intent stated in the comment below is
             * "was a client superseded"). */
            int was_supersede = (client_fd >= 0);
            if (client_fd >= 0) {
                close(client_fd);
                client_fd = -1;
                _ring_set_client(0, "takeover", 0);   /* 79-37 D-31 */
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
             * empty-ring pass.  Before 79-50 a superseded client's flush-
             * disconnect was always consumed at the loop top; with an open
             * decision window it is not, so BOTH branches clear it (and the
             * deadline): the old client is closed by the takeover itself, and
             * the new one must never be closed by the old window. */

            if (_http_write_all(pending.fd, (const unsigned char *)HTTP_RESPONSE_HEADER,
                                 sizeof(HTTP_RESPONSE_HEADER) - 1) == 0) {
                client_fd = pending.fd;
                /* boundary-trifft-nachfolgeclient fix: the ONE place a
                 * new client is ever promoted -- every successful
                 * takeover is a new client identity. See
                 * g_boundary_client_generation's doc comment above
                 * g_boundary_at_pushed. */
                g_client_generation++;
                /* boundary-trifft-nachfolgeclient REOPENED fix: a live
                 * attach means the story has moved on -- any unconsumed
                 * departed-generation record from further back (a client
                 * that died abruptly with no plant ever consuming the
                 * record) must not leak forward into some later, unrelated
                 * plant. See g_departed_client_generation's doc comment
                 * above g_boundary_at_pushed. */
                g_departed_client_generation = NO_CLIENT_GENERATION;
                /* 79-51 D2_ORPHAN_BEGIN */
                /* 79-51 runaway D2 (E4/E5): an orphan marker (planted with nobody attached and no departed record,
                 * NO_CLIENT_GENERATION) that stands at or below total_popped can only bound the client attaching
                 * now to 0 bytes: no byte of the title it was planted for is left in the ring (094204 :25.328/.338
                 * and 094408 :20.536/.550, `gen=-1 via=none ring_fill=0`). Discard it here, at promotion. A marker
                 * ABOVE total_popped stays: bytes stand before it, D-04 (rapid skip, last boundary wins) inherits it.
                 * Thread note: g_boundary_at_pushed is also cleared to -1 by the audio thread (stream re-create,
                 * pa_stream_flush); this block only ever writes -1 too, so the race is an idempotent clear. */
                if (g_boundary_at_pushed >= 0 && g_boundary_client_generation == NO_CLIENT_GENERATION) {
                    pthread_mutex_lock(&g_ring.lock);
                    int64_t orphan_popped = g_ring.total_popped;
                    pthread_mutex_unlock(&g_ring.lock);
                    int64_t orphan_at = g_boundary_at_pushed;
                    if (orphan_at >= 0 && orphan_at <= orphan_popped) {
                        BOUNDARY("boundary_discarded: orphan at attach (planted_gen=%lld current_gen=%lld) total_popped=%lld boundary=%lld",
                                 (long long)g_boundary_client_generation, (long long)g_client_generation,
                                 (long long)orphan_popped, (long long)orphan_at);
                        g_boundary_at_pushed = -1;
                    }
                }
                /* 79-51 D2_ORPHAN_END */
                _ring_set_client(1, "attach", (int64_t)g_client_generation);   /* 79-37 D-31 */
                /* D-34 R2_TAKEOVER_BEGIN */
                if (g_flush_disconnect) {
                    if (was_supersede && g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] flush-decide: ended by takeover\n", _ts);
                    }
                    g_flush_disconnect = 0;
                }
                _flush_decide_clear();
                /* D-34 R2_TAKEOVER_END */
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
            /* WR-03 (77-REVIEW): expire a leaked arm. While armed, the
             * gate below withholds all audio -- the track never reaches
             * the natural boundary that is otherwise the only recovery
             * path (POST /boundary's reset), so a leaked arm (Soloist
             * ignored the seek; WS dropped between arm and command; the
             * D-05 play-that-doesn't-flush case) would wedge playback
             * indefinitely without this. An arm is only ever meaningful
             * for the sub-second window up to Soloist's own flush; expire
             * it well past that. Runs once per 50ms tick, same thread
             * that stamps g_seek_arm_at, so no lock/atomic needed here. */
            if (g_seek_flush_armed > 0 && _elapsed_ms(&g_seek_arm_at) >= SEEK_ARM_TTL_MS) {
                BOUNDARY("seek_arm_expired: armed=%d", (int)g_seek_flush_armed);
                g_seek_flush_armed = 0;
            }
            _hold_timeout_check();   /* 79-37 D-31: one timeout check per drain tick */
            size_t drained_this_tick = 0;
            /* 79-50 (D-34 R2): while a flush-disconnect is pending -- its decision window
             * open, or decided but not yet executed (the loop top closes it first thing
             * next iteration) -- the post-flush audio is withheld too: nothing of the next
             * title may reach the old client if the window ends in a skip (E5, C_off wrote=4096
             * of it before the close). Beside the seek-arm gate; both keep every other
             * control request served by the outer poll() tick. */
            while (g_seek_flush_armed <= 0 && !g_flush_disconnect && drained_this_tick < HTTP_DRAIN_BUDGET) {
            unsigned char chunk[HTTP_DRAIN_CHUNK];
            /* 84-17 (plan-checker W2): pop only up to the marker. The old
             * loop popped a whole 16 KB chunk and cut it at the marker
             * afterwards, so up to 16383 bytes (46 ms) of the NEXT title
             * left the ring at every boundary and never reached the next
             * client; and the close sat inside `if (n > 0)`, so a marker
             * at the read pointer was only noticed once another byte
             * arrived. For a marker that applies to THIS client (the same
             * generation predicate as the post-pop check below) compute the
             * distance to it under the ring lock BEFORE popping: nothing
             * left -> close now without touching the ring; else pop at most
             * that far. A stale-generation marker is not capped (it is
             * discarded by the post-pop check, unchanged). */
            size_t pop_max = sizeof(chunk);
            {
                int64_t bnd = g_boundary_at_pushed;
                if (bnd >= 0
                    && (g_boundary_client_generation == NO_CLIENT_GENERATION
                        || g_boundary_client_generation == g_client_generation)) {
                    pthread_mutex_lock(&g_ring.lock);
                    int64_t popped_now = g_ring.total_popped;
                    pthread_mutex_unlock(&g_ring.lock);
                    int64_t remaining = bnd - popped_now;
                    if (remaining <= 0) {
                        BOUNDARY("boundary_reached: closing client fd=%d wrote=0 total_popped=%lld boundary=%lld trimmed=0",
                                 client_fd, (long long)popped_now, (long long)bnd);
                        /* 79-51 D2_DEPART_BEGIN */
                        g_departed_client_generation = g_client_generation;   /* 79-51 runaway D2 (E4): a bounded close departs its client too */
                        /* 79-51 D2_DEPART_END */
                        close(client_fd);
                        client_fd = -1;
                        _ring_set_client(0, "boundary", 0);   /* 79-37 D-31 */
                        g_boundary_at_pushed = -1;
                        if (g_debug_trace) {
                            char _ts[32];
                            _trace_ts(_ts, sizeof(_ts));
                            fprintf(stderr, "[fakepulse %s] client-close: bounded EOF at track boundary\n", _ts);
                        }
                        break;
                    }
                    if ((int64_t)pop_max > remaining) {
                        pop_max = (size_t)remaining;
                    }
                }
            }
            size_t n = _ring_pop_timed(&g_ring, chunk, pop_max,
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
                 * 84-17: the pop above is already capped at the marker for
                 * a marker that applies to this client, so this trim has
                 * nothing left to cut (`trimmed=0` in the boundary_reached
                 * line is the proof); it remains for the race where the
                 * daemon's own flush/drop advances total_popped between the
                 * cap computation and the pop. The former prototype
                 * limitation (pop-then-trim dropping up to 16383 bytes,
                 * ~46ms, of the next title at EVERY marker) is gone: the
                 * next connection continues from exactly the marker. */
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
                        /* boundary-trifft-nachfolgeclient fix, REVISED
                         * (see g_boundary_client_generation's doc comment
                         * above g_boundary_at_pushed for the full
                         * revision history): only discard when the
                         * marker was planted for a SPECIFIC, live
                         * predecessor client (a real, non-sentinel
                         * generation) that has since been superseded --
                         * that supersession is the confirmed defect.
                         * When the marker was planted with NO client
                         * attached at all (NO_CLIENT_GENERATION), there
                         * is no specific predecessor to protect, so the
                         * marker applies to whoever attaches next,
                         * exactly like the pre-fix code -- this is the
                         * deliberate, separately-tested D-04 rapid-skip
                         * "last boundary wins" behavior (Plan 77-05,
                         * commit 82a25b0), which an unconditional discard
                         * would have silently broken (caught by that
                         * test failing during this fix's own build). */
                        if (g_boundary_client_generation == NO_CLIENT_GENERATION
                            || g_boundary_client_generation == g_client_generation) {
                            int64_t usable = boundary - popped_before;
                            write_n = (usable > 0) ? (size_t)usable : 0;
                            at_boundary = 1;
                        } else {
                            BOUNDARY("boundary_discarded: stale generation (planted_gen=%lld current_gen=%lld) total_popped=%lld boundary=%lld",
                                     (long long)g_boundary_client_generation, (long long)g_client_generation,
                                     (long long)popped_after, (long long)boundary);
                            g_boundary_at_pushed = -1;
                        }
                    }
                }

                /* 84-22: -1 (hangup/hard error) and 4 (orphan bound) mean the client
                 * is gone; 2 (flush pending) and 3 (takeover pending) are NOT a
                 * departure -- the chunk is abandoned and the same iteration's
                 * tail hands over to the loop top's flush path / the takeover. */
                int write_rc = 0;
                long write_idle_ms = 0;
                if (write_n > 0) {
                    write_rc = _http_write_client(client_fd, chunk, write_n, &pending, &write_idle_ms);   /* 84-17: serves the control endpoints while the client stalls */
                }
                int write_failed = (write_rc == -1 || write_rc == 4);
                int write_deferred = (write_rc == 2 || write_rc == 3);

                if (write_failed) {
                    /* boundary-trifft-nachfolgeclient REOPENED fix: this
                     * is an ABRUPT departure -- the client is going away
                     * without ever having been closed via this file's own
                     * boundary_reached/takeover paths, so whatever
                     * POST /boundary arrives next (if any, before another
                     * client attaches) is presumed to be FOR this
                     * generation. See g_departed_client_generation's doc
                     * comment above g_boundary_at_pushed. */
                    g_departed_client_generation = g_client_generation;
                    close(client_fd);
                    client_fd = -1;
                    _ring_set_client(0, "departure", 0);   /* 79-37 D-31 */
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        if (write_rc == 4) {
                            fprintf(stderr, "[fakepulse %s] client-close: write orphan (no progress for %ld ms)\n", _ts, write_idle_ms);
                        } else {
                            fprintf(stderr, "[fakepulse %s] client-close: write error/disconnect\n", _ts);
                        }
                    }
                } else if (write_deferred) {
                    /* nothing to close here: the flush path / takeover closes the
                     * client with its own record and trace line */
                } else if (at_boundary) {
                    BOUNDARY("boundary_reached: closing client fd=%d wrote=%zu total_popped=%lld boundary=%lld trimmed=%zu",
                             client_fd, write_n, (long long)popped_after, (long long)boundary, n - write_n);
                    /* 79-51 D2_DEPART_BEGIN */
                    g_departed_client_generation = g_client_generation;   /* 79-51 runaway D2 (E4): a bounded close departs its client too */
                    /* 79-51 D2_DEPART_END */
                    close(client_fd);
                    client_fd = -1;
                    _ring_set_client(0, "boundary", 0);   /* 79-37 D-31 */
                    g_boundary_at_pushed = -1;
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] client-close: bounded EOF at track boundary\n", _ts);
                    }
                }
                drained_this_tick += n;
                if (n == 0 || write_failed || write_deferred || at_boundary || client_fd < 0)
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
                /* WR-02 (77-REVIEW): the ring-empty check and the
                 * g_ring_underrun_fired set must be decided as ONE
                 * operation under g_ring.lock, serialized against
                 * _ring_push's own reset of the same flag (also taken
                 * under this lock). The previous unlock-then-check-then-
                 * set left a window where _ring_push could land fresh
                 * data (fill>0, flag reset to 0) between our unlock and
                 * our set -- we would then still stomp the flag to 1
                 * despite the ring no longer being empty, permanently
                 * suppressing the next genuine empty-ring edge and
                 * stalling Soloist's writer (the exact stall this
                 * mechanism exists to prevent). atomic_int makes each
                 * access well-defined but not this read-then-write pair.
                 * The underflow_cb dispatch itself stays OUTSIDE the lock
                 * (below) -- calling into Soloist while holding
                 * g_ring.lock risks a lock-order inversion if the
                 * callback re-enters pa_stream_write()/_ring_push(). */
                int signalUnderrun;
                pthread_mutex_lock(&g_ring.lock);
                signalUnderrun = (g_ring.fill == 0 && !g_ring_underrun_fired
                                   && g_active_stream && g_active_stream->underflow_cb);
                /* 84-20 (Q2): the ring is only the transport; the sink is empty
                 * when the virtual sink is too. A held-back edge does NOT set
                 * the edge flag, so it fires once q_out has drained. */
                if (signalUnderrun && g_vsink.t_ms > 0) {
                    _vsink_settle_locked();
                    if (g_vsink.q_out > 0) {
                        signalUnderrun = 0;
                        g_vsink.suppressed++;
                    }
                }
                if (signalUnderrun) g_ring_underrun_fired = 1;
                pthread_mutex_unlock(&g_ring.lock);
                if (signalUnderrun)
                {
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
static atomic_int g_debug_trace = 0;
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
    _flush_decide_clear();   /* 79-50 */
    g_boundary_at_pushed = -1;  /* Phase 77 Spike 2: explicit reset, matching g_flush_disconnect */
    g_seek_flush_armed = 0;  /* Phase 77 Task 2: explicit reset, same one-shot-flag lifecycle */

    const char *traceEnv = getenv("SPOTON_FAKEPULSE_TRACE");
    if (traceEnv && *traceEnv) {
        g_debug_trace = atoi(traceEnv);
    } else if (getenv("SPOTON_FAKEPULSE_DEBUG") != NULL) {
        g_debug_trace = 1;
    }

    {
        /* 84-20: one unconditional line, so the daemon log says which virtual
         * sink depth this process runs with and where it came from. */
        const char *vsrc;
        long vt = _vsink_ms_src(&vsrc);
        fprintf(stderr, "[fakepulse] vsink: T_ms=%ld source=%s\n", vt, vsrc);
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
        long vt = _vsink_ms();
        pthread_mutex_lock(&g_ring.lock);
        int64_t fill = (int64_t)g_ring.fill;
        _vsink_sync_locked(vt);
        int64_t vq = vt > 0 ? g_vsink.q_out : 0;   /* 84-20: one (fill, Q) pair */
        pthread_mutex_unlock(&g_ring.lock);
        int64_t fill_input = fill * input_bps / 4;
        s->timing.write_index = s->bytes_written;
        s->timing.read_index = s->bytes_written - fill_input;
        if (vt > 0) {
            /* The virtual sink still holds vq ring bytes the client already
             * pulled: they are not played yet, in input bytes like fill. */
            s->timing.read_index -= vq * input_bps / 4;
            if (s->timing.read_index < 0) s->timing.read_index = 0;
        }

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
        s->timing.sink_usec = (pa_usec_t)((((int64_t)fill + vq) * 1000000) / RING_BYTES_PER_SEC);
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
    int was_active = (s != NULL && g_active_stream == s);
    if (g_active_stream == s) {
        g_active_stream = NULL;
        if (g_http_mode) {
            pthread_mutex_lock(&g_ring.lock);   /* 84-20: the sink dies with its stream */
            _vsink_reset_locked();
            g_vsink.running = 0;
            pthread_mutex_unlock(&g_ring.lock);
        }
    }
    if (g_http_mode && was_active) {
        /* 84-17 + 79-07 (84 WR-01): wake a waiting writer AND wait until it has
         * left pa_stream_write before the stream is freed. Only the active
         * stream has a writer; unref of a stale stream must not bump
         * flush_epoch (an in-flight write on the new stream would abandon). */
        _ring_release_writers_and_wait(&g_ring);
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
        /* WR-03 (77-REVIEW): this _ring_flush() IS the flush a pending
         * seek-arm was waiting for -- a stream re-create (rather than a
         * pa_stream_flush() call) is how Soloist's D-05 mismatch-play
         * sometimes discards the old stream's buffered audio. Consume one
         * arm here too (same CAS-floored-at-0 shape as pa_stream_flush's
         * own consumption), or the arm leaks: pa_stream_flush() is never
         * called for this path, so its consumption site never runs, and
         * the drain gate stays shut on a flush that already happened. */
        int connect_expected = atomic_load(&g_seek_flush_armed);
        while (connect_expected > 0
               && !atomic_compare_exchange_weak(&g_seek_flush_armed, &connect_expected, connect_expected - 1)) {
            /* connect_expected reloaded by the failed CAS; retry until we
             * consume one arm or observe it has already hit 0. */
        }
        /* soloist-browse-stutter fix: track this as the stream whose
         * underflow_cb the HTTP drain thread should invoke on a ring-empty
         * edge -- see g_active_stream's doc comment above g_ring. */
        g_active_stream = s;
        /* 84-20: the flush above emptied the virtual sink; it runs while the
         * new stream is uncorked. */
        pthread_mutex_lock(&g_ring.lock);
        _vsink_sync_locked(_vsink_ms());
        _vsink_set_running_locked(!s->corked);
        pthread_mutex_unlock(&g_ring.lock);
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
    if (g_http_mode) {
        if (g_active_stream == s) {
            pthread_mutex_lock(&g_ring.lock);   /* 84-20: a disconnected stream drains nothing */
            _vsink_reset_locked();
            g_vsink.running = 0;
            pthread_mutex_unlock(&g_ring.lock);
            /* 84-17 + 79-07 (84 WR-01): a writer waiting for room must not outlive
             * its stream -- wake it and wait until it has left pa_stream_write. */
            _ring_release_writers_and_wait(&g_ring);
        }
    }
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
        if (g_http_mode && s == g_active_stream) {
            /* 84-20: settle under the old state, then the sink drains only
             * while the stream is uncorked; the clock restarts either way. */
            long vt = _vsink_ms();
            pthread_mutex_lock(&g_ring.lock);
            _vsink_sync_locked(vt);
            _vsink_set_running_locked(!s->corked);
            pthread_mutex_unlock(&g_ring.lock);
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
        long vt = _vsink_ms();
        if (vt > 0) {
            int64_t vq, vsup;
            pthread_mutex_lock(&g_ring.lock);
            _vsink_sync_locked(vt);
            vq = g_vsink.q_out;
            vsup = g_vsink.suppressed;
            pthread_mutex_unlock(&g_ring.lock);
            BOUNDARY("vsink: flush q_out=%lld suppressed_underflows=%lld T_ms=%ld",
                     (long long)vq, (long long)vsup, vt);
        }
        _ring_flush(&g_ring);       /* also empties the virtual sink */
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
        /* WR-01 (77-REVIEW): a plain check-then-decrement here races the
         * POST /boundary handler's unconditional `g_seek_flush_armed = 0`
         * reset (different thread) -- read sees >0, boundary thread stores
         * 0, this thread then stores -1. atomic_int makes each individual
         * access well-defined, but not the read-modify-write pair as a
         * whole. A CAS loop makes the whole "consume one, floored at 0"
         * operation atomic: if the boundary handler's store races in
         * between our load and store, the CAS fails, `expected` reloads to
         * the boundary's freshly-stored 0, and the loop exits with
         * expected == 0 -- correctly falling through to the unarmed
         * disconnect path instead of driving the counter negative. */
        int expected = atomic_load(&g_seek_flush_armed);
        while (expected > 0
               && !atomic_compare_exchange_weak(&g_seek_flush_armed, &expected, expected - 1)) {
            /* expected reloaded by the failed CAS; retry until we consume
             * one arm or observe it has already hit 0. */
        }
        if (expected > 0) {
            /* armed flush consumed -- stay connected */
        } else {
            /* 79-47 (D-34): an unarmed flush while browse keep is set is the
             * daemon's own flush for a title Control did not change (an app
             * seek, an app next/previous before Control redirects it): keep
             * the client, exactly as an armed flush does. The arm above is
             * consumed first, so a connect /seek-arm keeps its meaning. The
             * marked block is what t/soloist/48's browse-keep mutant cuts:
             * without it every unarmed flush disconnects, as before 79-47. */
            int keep = 0;
            /* D-34 BROWSE_KEEP_BEGIN */
            keep = atomic_load(&g_browse_keep) ? 1 : 0;
            /* D-34 BROWSE_KEEP_END */
            if (keep) {
                if (g_debug_trace) {
                    char _ts[32];
                    _trace_ts(_ts, sizeof(_ts));
                    fprintf(stderr, "[fakepulse %s] flush-keep: browse keep set, active HTTP client stays\n", _ts);
                }
                BOUNDARY("flush_keep: browse keep set, no flush-disconnect");
            } else {
                /* 79-50 (D-34 R2): the unarmed, not-browse-kept flush. The decision
                 * deadline is stored BEFORE the flag: the HTTP thread must never see
                 * the flag without it and close at once. W = 0 is no window (the
                 * contract of every older cell and of a shim without 79-50). */
                long decide_ms = _flush_decide_env_ms();
                if (decide_ms > 0) {
                    long now = _mono_ms();
                    long dl = (long)((unsigned long)now + (unsigned long)decide_ms);
                    if (dl == 0) {
                        dl = 1;    /* 0 means "no window" */
                    }
                    atomic_store(&g_flush_decide_promoted, 0);
                    atomic_store(&g_flush_decide_t0, now != 0 ? now : 1);
                    atomic_store(&g_flush_decide_deadline, dl);
                    g_flush_disconnect = 1;
                    if (g_debug_trace) {
                        char _ts[32];
                        _trace_ts(_ts, sizeof(_ts));
                        fprintf(stderr, "[fakepulse %s] flush-decide: open window_ms=%ld\n", _ts, decide_ms);
                    }
                    BOUNDARY("flush_decide: open window_ms=%ld", decide_ms);
                } else {
                    _flush_decide_clear();
                    g_flush_disconnect = 1;
                }
            }
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
        long vt = _vsink_ms();
        size_t vroom = 0;
        pthread_mutex_lock(&g_ring.lock);
        size_t freeSpace = g_ring.capacity - g_ring.fill;
        size_t fillNow = g_ring.fill;
        _vsink_sync_locked(vt);
        if (vt > 0) {
            /* 84-20: what is still free in the virtual sink, in the stream's
             * INPUT bytes (S16 input is half the ring bytes). */
            int64_t tb = (int64_t)vt * RING_BYTES_PER_SEC / 1000;
            int64_t room = tb > g_vsink.q_out ? tb - g_vsink.q_out : 0;
            if (s && s->sample_spec.format == PA_SAMPLE_S16LE) room /= 2;
            vroom = (size_t)room;
        }
        pthread_mutex_unlock(&g_ring.lock);
        /* 84-17: what the daemon is told is the free space minus
         * RING_WRITE_MARGIN, 0 at or below it (see the macro); remembered for
         * the write_beyond_writable line. Never more than the free space --
         * t/48 pins it. */
        freeSpace = freeSpace > (size_t)RING_WRITE_MARGIN ? freeSpace - (size_t)RING_WRITE_MARGIN : 0;
        if (vt > 0 && freeSpace > vroom) freeSpace = vroom;   /* never more than the real free space */
        g_last_writable_reported = freeSpace;
        g_last_writable_query_ms = _mono_ms();
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

#ifdef FAKE_LIBPULSE_TEST
/* 79-07 (84 WR-01), harness only: a writer that was woken from a full ring
 * sleeps this many ms before it touches the stream again, and sets
 * g_test_writer_left right after its last access to the stream. Never
 * compiled into libpulse.so.0. */
static atomic_int g_test_writer_wake_delay_ms = 0;
static atomic_int g_test_writer_left = 0;
#endif

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

    /* 79-07 (84 WR-01): register as a writer for the whole call; the matching
     * decrement sits after the last access to `s`. The flush epoch seen here is
     * the one the ring write abandons against, so a teardown that lands between
     * this point and the ring wait is never missed (it would otherwise leave the
     * teardown waiting out the whole write ceiling). */
    pthread_mutex_lock(&g_ring.lock);
    g_ring.writers_in++;
    uint64_t entry_epoch = g_ring.flush_epoch;
    pthread_mutex_unlock(&g_ring.lock);
    g_tls_in_write = 1;

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
            ring_write_t w;
            memset(&w, 0, sizeof(w));
            size_t need = (s->sample_spec.format == PA_SAMPLE_S16LE) ? nbytes * 2 : nbytes;
            long vt = _vsink_ms();
            pthread_mutex_lock(&g_ring.lock);
            w.epoch = entry_epoch;
            size_t freeAtEntry = g_ring.capacity - g_ring.fill;
            /* 84-20: the sink holds the chunk from the moment it is written --
             * counted BEFORE it lands in the ring, so the HTTP thread can never
             * see an empty ring and an empty sink between the two. What the
             * ring then refuses or abandons is taken back below. */
            _vsink_sync_locked(vt);
            if (vt > 0) g_vsink.q_out += (int64_t)need;
            pthread_mutex_unlock(&g_ring.lock);
            long t_in = _mono_ms();
            _convert_and_push(s->sample_spec.format, data, nbytes, &w);
#ifdef FAKE_LIBPULSE_TEST
            {
                int d = atomic_load(&g_test_writer_wake_delay_ms);
                if (d > 0) usleep((useconds_t)d * 1000);
            }
#endif
            if (vt > 0 && (w.refused > 0 || w.abandoned_bytes > 0)) {
                int64_t unaccepted = w.refused + w.abandoned_bytes;
                pthread_mutex_lock(&g_ring.lock);
                g_vsink.q_out = g_vsink.q_out > unaccepted ? g_vsink.q_out - unaccepted : 0;
                pthread_mutex_unlock(&g_ring.lock);
            }
            /* 84-17: a write bigger than the free space is the one situation
             * the ring has to wait or refuse in -- one dark line each time, so
             * the daemon's overshoot (size, free, last value it was told) is
             * read from the log instead of inferred. */
            if (need > freeAtEntry) {
                long since_q = g_last_writable_query_ms ? t_in - g_last_writable_query_ms : -1;
                BOUNDARY("write_beyond_writable: nbytes=%zu free=%zu last_writable_reported=%zu ms_since_writable_query=%ld waited_ms=%ld outcome=%s refused=%lld abandoned=%lld",
                         nbytes, freeAtEntry, (size_t)g_last_writable_reported, since_q, w.waited_ms,
                         w.abandoned ? "abandoned_by_flush" : (w.refused > 0 ? "refused_at_ceiling" : "complete"),
                         (long long)w.refused, (long long)w.abandoned_bytes);
            }
            if (w.refused > 0) {
                /* Loud regardless of the boundary spike: audio was lost. */
                fprintf(stderr, "[fakepulse] write_refused: bytes=%lld waited_ms=%ld (ring full for the whole ceiling; counted in drops=)\n",
                        (long long)w.refused, w.waited_ms);
            }
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
            int64_t drops = g_ring.drops_total;
            pthread_mutex_unlock(&g_ring.lock);
            char _ts[32];
            _trace_ts(_ts, sizeof(_ts));
            fprintf(stderr, "[fakepulse BOUNDARY ts=%s] write_summary: "
                    "bytes_written=%lld ring_fill=%zu calls=%d bytes_since=%lld corked=%d drops=%lld\n",
                    _ts, (long long)s->bytes_written, fill,
                    g_boundary_write_count, (long long)g_boundary_write_bytes_since,
                    s->corked, (long long)drops);
            g_boundary_write_count = 0;
            g_boundary_write_bytes_since = 0;
        }
    }

#ifdef FAKE_LIBPULSE_TEST
    atomic_store(&g_test_writer_left, 1);
#endif

    /* 79-07 (84 WR-01): last access to `s` is behind us -- a teardown waiting
     * in _ring_release_writers_and_wait may free the stream from here on. */
    g_tls_in_write = 0;
    pthread_mutex_lock(&g_ring.lock);
    g_ring.writers_in--;
    pthread_cond_broadcast(&g_ring.writers_gone);
    pthread_mutex_unlock(&g_ring.lock);

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
#include <ifaddrs.h>
#include <net/if.h>

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
    struct timeval start;
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
        if (_elapsed_ms(&start) >= timeout_ms) {
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

    struct timeval start;
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
        if (got >= want) {
            return 0;
        }
        if (_elapsed_ms(&start) >= timeout_ms) {
            return -1;
        }
    }
    return 0;
}

/* Reads exactly 'want' raw bytes on an already-streaming connection (no
 * HTTP header parsing, unlike _test_read_response) -- bounded by
 * timeout_ms, measured in elapsed milliseconds (quick-261022-ca3: a
 * whole-second difference fired at the first second rollover). Returns 0
 * on success, -1 on timeout, -2 on EOF or read error. Complete data is
 * reported as success even when it arrived at the very edge of the budget. */
static int _test_read_bytes(int fd, unsigned char *out, size_t want, int timeout_ms) {
    size_t got = 0;
    struct timeval start;
    gettimeofday(&start, NULL);
    while (got < want) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, 200);
        if (rc > 0 && (pfd.revents & POLLIN)) {
            ssize_t n = read(fd, out + got, want - got);
            if (n <= 0) {
                return -2;
            }
            got += (size_t)n;
        }
        if (got >= want) {
            return 0;
        }
        if (_elapsed_ms(&start) >= timeout_ms) {
            return -1;
        }
    }
    return 0;
}

/* quick-261022-ca3: second-boundary self-test of the three read helpers
 * above. A sub-second read budget has to be measured in elapsed
 * milliseconds. The probe arms itself at tv_usec >= 950000, so a wall-clock
 * second rollover lies at most 50 ms ahead; the writer thread sends the
 * payload 5 ms AFTER that rollover. The data therefore arrives about 5-55
 * ms into a 500 ms budget with a second boundary in between - a helper that
 * compares whole seconds reports a timeout for data that arrived on time. */
struct _test_boundary_writer_ctx {
    int fd;
    time_t armed_sec;
    const unsigned char *pre;
    size_t pre_len;
    const unsigned char *post;
    size_t post_len;
    int werr;
};

static int _test_write_all(int fd, const unsigned char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n <= 0) {
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static void *_test_boundary_writer_fn(void *arg) {
    struct _test_boundary_writer_ctx *c = (struct _test_boundary_writer_ctx *)arg;
    if (c->pre_len > 0 && _test_write_all(c->fd, c->pre, c->pre_len) != 0) {
        c->werr = 1;
    }
    for (;;) {
        struct timeval now;
        gettimeofday(&now, NULL);
        if (now.tv_sec != c->armed_sec) {
            break;
        }
        usleep(1000);
    }
    usleep(5000);
    if (_test_write_all(c->fd, c->post, c->post_len) != 0) {
        c->werr = 1;
    }
    return NULL;
}

/* Sleeps in 1 ms steps until tv_usec >= 950000 and returns that second. */
static time_t _test_arm_second_boundary(void) {
    struct timeval now;
    for (;;) {
        gettimeofday(&now, NULL);
        if (now.tv_usec >= 950000) {
            return now.tv_sec;
        }
        usleep(1000);
    }
}

/* One probe: kind 0 = _test_read_bytes, 1 = _test_read_header,
 * 2 = _test_read_response. Returns the helper's return code (0 only when
 * the bytes also match), -9 when the probe could not be armed in 10
 * attempts. *ms_out receives the elapsed milliseconds of the helper call. */
static int _test_boundary_probe(int kind, long *ms_out) {
    static const unsigned char known[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    static const char hdr[] = "HTTP/1.0 200 OK\r\nContent-Type: audio/x-pcm\r\n\r\n";
    *ms_out = 0;
    for (int attempt = 0; attempt < 10; attempt++) {
        time_t sec = _test_arm_second_boundary();
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
            return -9;
        }
        struct timeval chk;
        gettimeofday(&chk, NULL);
        if (chk.tv_sec != sec) {
            close(sv[0]);
            close(sv[1]);
            continue;
        }
        struct _test_boundary_writer_ctx c;
        memset(&c, 0, sizeof(c));
        c.fd = sv[1];
        c.armed_sec = sec;
        if (kind == 0) {
            c.post = known;
            c.post_len = sizeof(known);
        } else if (kind == 1) {
            c.post = (const unsigned char *)hdr;
            c.post_len = sizeof(hdr) - 1;
        } else {
            c.pre = (const unsigned char *)hdr;
            c.pre_len = sizeof(hdr) - 1;
            c.post = known;
            c.post_len = sizeof(known);
        }
        pthread_t th;
        if (pthread_create(&th, NULL, _test_boundary_writer_fn, &c) != 0) {
            close(sv[0]);
            close(sv[1]);
            return -9;
        }
        unsigned char buf[8];
        memset(buf, 0, sizeof(buf));
        struct timeval t0;
        gettimeofday(&t0, NULL);
        int rc;
        if (kind == 0) {
            rc = _test_read_bytes(sv[0], buf, sizeof(buf), 500);
        } else if (kind == 1) {
            rc = _test_read_header(sv[0], 500);
        } else {
            rc = _test_read_response(sv[0], buf, sizeof(buf), 500);
        }
        *ms_out = _elapsed_ms(&t0);
        pthread_join(th, NULL);
        close(sv[0]);
        close(sv[1]);
        if (rc == 0 && kind != 1 && memcmp(buf, known, sizeof(known)) != 0) {
            rc = -3;
        }
        if (rc == 0 && c.werr) {
            rc = -4;
        }
        return rc;
    }
    return -9;
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
        struct timeval start;
        gettimeofday(&start, NULL);
        while (rlen < sizeof(resp) - 1) {
            struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
            if (poll(&pfd, 1, 200) > 0) {
                ssize_t n = read(fd, resp + rlen, sizeof(resp) - 1 - rlen);
                if (n <= 0) break;
                rlen += (size_t)n;
            }
            if (_elapsed_ms(&start) >= 2000) break;
        }
        resp[rlen] = '\0';
        ok = (strncmp(resp, "HTTP/1.0 200 OK", 15) == 0);
    }
    close(fd);
    return ok;
}

/* debug connect-seek-stoppt-wiedergabe (2026-09-24): opens a loopback
 * connection and writes a bare control POST WITHOUT reading the response
 * -- the exact shape of Control.pm's _loopbackPost (one syswrite, no
 * read), so a test can race the HTTP thread's accept/read of the request
 * against a pa_stream_flush() on the test thread. Returns the fd (caller
 * reads the response via _test_read_control_ok and closes), -1 on
 * failure. */
static int _test_post_raw(int port, const char *path) {
    int fd = _test_connect_loopback(port);
    if (fd < 0) {
        return -1;
    }
    char req[128];
    int reqLen = snprintf(req, sizeof(req), "POST %s HTTP/1.0\r\nConnection: close\r\n\r\n", path);
    if (reqLen <= 0 || write(fd, req, (size_t)reqLen) != (ssize_t)reqLen) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Reads a control response on fd until EOF or timeout_ms; returns 1 iff
 * it starts with "HTTP/1.0 200 OK" (0 on EOF-without-data, i.e. the
 * request was dropped unread, or on any other status). */
static int _test_read_control_ok(int fd, int timeout_ms) {
    char resp[128];
    size_t rlen = 0;
    struct timeval start, now;
    gettimeofday(&start, NULL);
    while (rlen < sizeof(resp) - 1) {
        struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
        if (poll(&pfd, 1, 20) > 0) {
            ssize_t n = read(fd, resp + rlen, sizeof(resp) - 1 - rlen);
            if (n <= 0) break;
            rlen += (size_t)n;
        }
        gettimeofday(&now, NULL);
        if ((now.tv_sec - start.tv_sec) * 1000 + (now.tv_usec - start.tv_usec) / 1000 >= timeout_ms) break;
    }
    resp[rlen] = '\0';
    return strncmp(resp, "HTTP/1.0 200 OK", 15) == 0;
}

/* Watches an attached streaming client for EOF for up to window_ms,
 * discarding any bytes that arrive. Returns 1 on EOF/error, 0 if the
 * connection stayed open for the whole window. */
static int _test_saw_eof(int fd, int window_ms) {
    unsigned char sink[4096];
    struct timeval start, now;
    gettimeofday(&start, NULL);
    for (;;) {
        struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
        if (poll(&pfd, 1, 20) > 0) {
            ssize_t n = read(fd, sink, sizeof(sink));
            if (n == 0) return 1;
            if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return 1;
        }
        gettimeofday(&now, NULL);
        if ((now.tv_sec - start.tv_sec) * 1000 + (now.tv_usec - start.tv_usec) / 1000 >= window_ms) return 0;
    }
}

/* 84-17 (L1 repair): helpers for the POST /boundary reply-body checks.
 *
 * _test_post_control_body: the _test_post_control shape (fresh loopback
 * connection, bare POST, `Connection: close`) but it returns the response
 * BODY (everything after the blank line, read until EOF within 2 s) and
 * validates the framing: a 200 OK, a Content-Length header and a body
 * whose length equals it. Returns 1 only when all of that holds and the
 * body is non-empty (a legacy `Content-Length: 0` answer returns 0). */
static int _test_post_control_body(int port, const char *path, char *body, size_t cap) {
    body[0] = '\0';
    int fd = _test_connect_loopback(port);
    if (fd < 0) {
        return 0;
    }
    char req[160];
    int reqLen = snprintf(req, sizeof(req), "POST %s HTTP/1.0\r\nConnection: close\r\n\r\n", path);
    char resp[1024];
    size_t rlen = 0;
    if (reqLen > 0 && write(fd, req, (size_t)reqLen) == (ssize_t)reqLen) {
        struct timeval start;
        gettimeofday(&start, NULL);
        while (rlen < sizeof(resp) - 1) {
            struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
            if (poll(&pfd, 1, 200) > 0) {
                ssize_t n = read(fd, resp + rlen, sizeof(resp) - 1 - rlen);
                if (n <= 0) break;
                rlen += (size_t)n;
            }
            if (_elapsed_ms(&start) >= 2000) break;
        }
    }
    close(fd);
    resp[rlen] = '\0';
    if (strncmp(resp, "HTTP/1.0 200 OK", 15) != 0) {
        return 0;
    }
    char *sep = strstr(resp, "\r\n\r\n");
    if (!sep) {
        return 0;
    }
    const char *b = sep + 4;
    snprintf(body, cap, "%s", b);
    const char *cl = strstr(resp, "Content-Length: ");
    if (!cl || cl > sep) {
        return 0;
    }
    long want = strtol(cl + 16, NULL, 10);
    return want > 0 && want == (long)strlen(b);
}

/* Finds `key` (e.g. "via=") at the start of the body or after a space and
 * returns a pointer to its value, or NULL. */
static const char *_test_body_find(const char *body, const char *key) {
    size_t kl = strlen(key);
    for (const char *p = body; (p = strstr(p, key)) != NULL; p += kl) {
        if (p == body || p[-1] == ' ') {
            return p + kl;
        }
    }
    return NULL;
}

/* Copies the token after `key` (up to a space/newline) into out. */
static int _test_body_str(const char *body, const char *key, char *out, size_t cap) {
    const char *v = _test_body_find(body, key);
    if (!v) {
        out[0] = '\0';
        return 0;
    }
    size_t n = 0;
    while (v[n] && v[n] != ' ' && v[n] != '\n' && n + 1 < cap) {
        out[n] = v[n];
        n++;
    }
    out[n] = '\0';
    return 1;
}

/* Parses the integer after `key`; -1 when the key is absent. */
static long long _test_body_i64(const char *body, const char *key) {
    const char *v = _test_body_find(body, key);
    return v ? strtoll(v, NULL, 10) : -1;
}

/* Empties the ring the way the older blocks do (same-TU struct access),
 * keeping total_pushed - total_popped == fill, and clears the marker. */
static void _test_ring_reset(void) {
    pthread_mutex_lock(&g_ring.lock);
    g_ring.total_popped += (int64_t)g_ring.fill;
    g_ring.head = g_ring.tail = g_ring.fill = 0;
    g_ring.client_connected = 0;
    /* 79-37 D-31: no cell inherits a hold, an empty streak or a suppression
     * from the previous one. */
    g_ring.empty_valid = 0;
    g_ring.empty_since_ms = 0;
    g_ring.hold_at = -1;
    g_ring.hold_since_ms = 0;
    g_ring.suppress_valid = 0;
    g_ring.hold_suppress_until_ms = 0;
    g_ring.hold_expired_at = -1;
    g_ring.hold_armed_total = 0;
    g_ring.hold_last_release[0] = '\0';
    pthread_mutex_unlock(&g_ring.lock);
    g_boundary_at_pushed = -1;
    g_seek_flush_armed = 0;
}

/* 84-17 (backpressure, user decision "never discard, daemon waits"):
 * helpers for the full-ring write cases. A writer thread issues ONE
 * pa_stream_write the way the daemon does; the test thread plays the
 * consumer through _ring_pop_timed (same TU), so no HTTP client is
 * needed and the ring never races the HTTP thread (client_connected=0).
 * The ring content is a consecutive int32 sequence (stream format S32LE),
 * so "nothing discarded, nothing reordered" is checked byte-exactly. */
/* 84-17 (found live): the writable_size the daemon is told is the free space
 * minus this reserve (0 when the free space is at or below it). Literal here
 * on purpose: the test states the contract, not the implementation's macro. */
#define _TEST_WRITE_MARGIN ((size_t)131072)

typedef struct {
    pa_stream  *s;
    const void *data;
    size_t      nbytes;
    atomic_int  done;
    long        elapsed_ms;
} _test_writer_t;

static void *_test_writer_thread(void *arg) {
    _test_writer_t *w = (_test_writer_t *)arg;
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    pa_stream_write(w->s, w->data, w->nbytes, NULL, 0, 0);
    gettimeofday(&t1, NULL);
    w->elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
    atomic_store(&w->done, 1);
    return NULL;
}

static int64_t _test_drops(void) {
    pthread_mutex_lock(&g_ring.lock);
    int64_t d = g_ring.drops_total;
    pthread_mutex_unlock(&g_ring.lock);
    return d;
}

static size_t _test_fill(void) {
    pthread_mutex_lock(&g_ring.lock);
    size_t f = g_ring.fill;
    pthread_mutex_unlock(&g_ring.lock);
    return f;
}

/* nbytes of consecutive int32 starting at *seq (advances *seq). Caller frees. */
static int32_t *_test_seq_buf(size_t nbytes, int32_t *seq) {
    size_t n = nbytes / sizeof(int32_t);
    int32_t *b = malloc(nbytes);
    if (!b) return NULL;
    for (size_t i = 0; i < n; i++) b[i] = (*seq)++;
    return b;
}

/* Pop everything the ring holds until `done` is set and the ring is empty
 * (or `guard_ms` passes); verify the consecutive-int32 invariant starting
 * at *expect. Returns the number of bytes popped; *bad counts mismatches. */
static size_t _test_consume_all(atomic_int *done, int32_t *expect, long *bad, long guard_ms) {
    static unsigned char buf[65536];
    size_t total = 0;
    struct timeval t0, now;
    gettimeofday(&t0, NULL);
    for (;;) {
        size_t got = _ring_pop_timed(&g_ring, buf, sizeof(buf), 20);
        for (size_t i = 0; i + 3 < got; i += 4) {
            int32_t v;
            memcpy(&v, buf + i, 4);
            if (v != *expect) (*bad)++;
            (*expect)++;
        }
        total += got;
        if (got == 0 && (!done || atomic_load(done)) && _test_fill() == 0) break;
        gettimeofday(&now, NULL);
        if ((now.tv_sec - t0.tv_sec) * 1000 + (now.tv_usec - t0.tv_usec) / 1000 > guard_ms) break;
    }
    return total;
}

/* One natural-end-shaped run for the reply/placement checks: attach a
 * streaming client, push floatsA samples (0.25) and let the client read
 * ALL of them (so the ring is empty again and its last empty-to-filled
 * position is where the next push lands), push floatsB samples (0.5),
 * POST `path`, then read the client to EOF counting what it received.
 * `base` is total_pushed at the start; `pushed_end`/`fill_after` are read
 * once the client has seen EOF. */
typedef struct {
    char    body[512];
    int     post_ok;
    int     attached;
    int     eof;
    size_t  received;
    int64_t base;
    int64_t pushed_end;
    size_t  fill_after;
} _test_brun_t;

static void _test_boundary_run(pa_stream *s, int port, const char *path,
                               size_t floatsA, size_t floatsB, _test_brun_t *r) {
    memset(r, 0, sizeof(*r));
    _test_ring_reset();
    pthread_mutex_lock(&g_ring.lock);
    r->base = g_ring.total_pushed;
    pthread_mutex_unlock(&g_ring.lock);

    static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
    int fd = _test_connect_loopback(port);
    if (fd < 0 || write(fd, getReq, sizeof(getReq) - 1) < 0 || _test_read_header(fd, 3000) != 0) {
        if (fd >= 0) close(fd);
        return;
    }
    r->attached = 1;

    size_t bytesA = floatsA * sizeof(float);
    float *a = malloc(bytesA);
    unsigned char *sink = malloc(bytesA);
    if (!a || !sink) {
        free(a);
        free(sink);
        close(fd);
        return;
    }
    for (size_t i = 0; i < floatsA; i++) a[i] = 0.25f;
    pa_stream_write(s, a, bytesA, NULL, 0, 0);
    int gotA = (_test_read_bytes(fd, sink, bytesA, 8000) == 0);
    free(a);
    free(sink);
    if (!gotA) {
        close(fd);
        return;
    }
    r->received = bytesA;

    if (floatsB > 0) {
        float *b = malloc(floatsB * sizeof(float));
        if (b) {
            for (size_t i = 0; i < floatsB; i++) b[i] = 0.5f;
            pa_stream_write(s, b, floatsB * sizeof(float), NULL, 0, 0);
            free(b);
        }
    }

    r->post_ok = _test_post_control_body(port, path, r->body, sizeof(r->body));

    unsigned char buf[65536];
    for (int i = 0; i < 400 && !r->eof; i++) {
        struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
        if (poll(&pfd, 1, 10) > 0) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n == 0) {
                r->eof = 1;
            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                r->eof = 1;
            } else if (n > 0) {
                r->received += (size_t)n;
            }
        }
    }
    close(fd);
    pthread_mutex_lock(&g_ring.lock);
    r->pushed_end = g_ring.total_pushed;
    r->fill_after = g_ring.fill;
    pthread_mutex_unlock(&g_ring.lock);
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

/* 84-20 (Q2, virtual sink): helpers of the `vsink` cases. The harness clock
 * is a test-only override of the shim's monotonic clock (g_vsink_test_clock_us,
 * declared next to the sink; _Atomic, so ThreadSanitizer sees no race on the
 * override itself): non-zero = the shim reads it instead of CLOCK_MONOTONIC.
 * Frozen = no advance between two calls. The byte rates below are literals on
 * purpose: the test states the contract (352800 B/s of S32LE stereo), not the
 * implementation's macro. */
#define _TEST_VSINK_CLOCK0_US 7000000000LL

/* The compiled default T (the cases read it, never assume it). */
static int _test_vsink_default_ms(void) {
    return VSINK_MS_DEFAULT;
}

static atomic_int _test_vsink_uf = 0;

static void _test_vsink_uf_cb(pa_stream *s, void *userdata) {
    (void)s;
    (void)userdata;
    atomic_fetch_add(&_test_vsink_uf, 1);
}

/* ms < 0 unsets the variable (the compiled default then applies). */
static void _test_vsink_env(long ms) {
    if (ms < 0) {
        unsetenv("SPOTON_FAKEPULSE_VSINK_MS");
        return;
    }
    char b[24];
    snprintf(b, sizeof(b), "%ld", ms);
    setenv("SPOTON_FAKEPULSE_VSINK_MS", b, 1);
}

static void _test_vsink_clock_set(long long us) {
    atomic_store(&g_vsink_test_clock_us, us);
}

static void _test_vsink_clock_advance_ms(long ms) {
    atomic_fetch_add(&g_vsink_test_clock_us, (long long)ms * 1000LL);
}

static void _test_vsink_cork(pa_stream *s, int corked) {
    pa_operation *op = pa_stream_cork(s, corked, NULL, NULL);
    if (op) {
        pa_operation_unref(op);
    }
}

/* A flush the way a seek does it (armed): empties ring and virtual sink and
 * leaves any attached client alone. */
static void _test_vsink_flush(pa_stream *s) {
    g_seek_flush_armed = 1;
    pa_operation *op = pa_stream_flush(s, NULL, NULL);
    if (op) {
        pa_operation_unref(op);
    }
    g_seek_flush_armed = 0;
}

static void _test_vsink_update_timing(pa_stream *s) {
    pa_operation *op = pa_stream_update_timing_info(s, NULL, NULL);
    if (op) {
        pa_operation_unref(op);
    }
}

/* Starts a vsink case: T in ms (< 0 = env unset), sample format, corked or
 * not, the harness clock frozen at a known instant, an empty sink and ring. */
static void _test_vsink_begin(pa_stream *s, pa_sample_format_t fmt, long t_ms, int corked) {
    s->sample_spec.format = fmt;
    _test_vsink_env(t_ms);
    _test_vsink_clock_set(_TEST_VSINK_CLOCK0_US);
    _test_vsink_cork(s, corked);
    _test_vsink_flush(s);
    _test_ring_reset();
}

/* Leaves the stream as the older cases expect it: uncorked, empty, T off,
 * the real clock, the saved format. */
static void _test_vsink_end(pa_stream *s, pa_sample_format_t savedFmt) {
    _test_vsink_cork(s, 0);
    _test_vsink_flush(s);
    _test_vsink_env(0);
    (void)pa_stream_writable_size(s);
    _test_vsink_clock_set(0);
    s->sample_spec.format = savedFmt;
    _test_ring_reset();
}

static void _test_vsink_write_n(pa_stream *s, size_t nbytes) {
    void *b = calloc(1, nbytes);
    if (b) {
        pa_stream_write(s, b, nbytes, NULL, 0, 0);
        free(b);
    }
}

/* Pops up to n ring bytes the way a client would (the ring is detached from
 * the HTTP thread in these cases). */
static size_t _test_vsink_pop(size_t n) {
    unsigned char *b = malloc(n ? n : 1);
    size_t got = 0;
    if (b) {
        while (got < n) {
            size_t k = _ring_pop_timed(&g_ring, b, n - got, 0);
            if (!k) {
                break;
            }
            got += k;
        }
        free(b);
    }
    return got;
}

/* 84-22 (F-20-WRITER) harness helpers. The writer cases need a client that
 * stops reading (tiny receive buffer, SO_RCVBUF 2048 before connect -- the
 * 84-17 stalled-client form), a COUNTER ramp pushed through pa_stream_write
 * (contiguity is checkable: sample k is float k/2^24, which the shim converts
 * to a known S32), and a way to read the trace lines the HTTP thread writes
 * to stderr (the literals the live gate counts). */
#define _TEST_WR_SAMPLES ((size_t)786432)   /* 3 MiB of S32: fits the 20 s ring, far above what the socket buffers take */

static float _test_wr_ramp_f(size_t k) {
    return (float)k / 16777216.0f;
}

static long _test_wr_now_ms(void) {
    struct timeval t;
    gettimeofday(&t, NULL);
    return (long)(t.tv_sec * 1000L + t.tv_usec / 1000);
}

/* Attaches a /stream client with a 2 KiB receive buffer and consumes the
 * response header. Returns the fd or -1. */
static int _test_wr_attach(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int rcv = 2048;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons((uint16_t)port);
    static const char req[] = "GET /stream HTTP/1.0\r\n\r\n";
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0
        || write(fd, req, sizeof(req) - 1) <= 0
        || _test_read_header(fd, 3000) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Pushes ramp samples [from, from + count) the way the daemon does (float32). */
static void _test_wr_push(pa_stream *s, size_t from, size_t count) {
    size_t step = 32768;
    float *blk = malloc(step * sizeof(float));
    if (!blk) {
        return;
    }
    for (size_t off = 0; off < count; off += step) {
        size_t n = (count - off < step) ? (count - off) : step;
        for (size_t i = 0; i < n; i++) {
            blk[i] = _test_wr_ramp_f(from + off + i);
        }
        pa_stream_write(s, blk, n * sizeof(float), NULL, 0, 0);
    }
    free(blk);
}

static int _test_wr_connected(void) {
    pthread_mutex_lock(&g_ring.lock);
    int c = g_ring.client_connected;
    pthread_mutex_unlock(&g_ring.lock);
    return c;
}

/* The HTTP thread is stalled in its client write when the ring holds bytes
 * that stay put: fill > 0 and unchanged for 300 ms (<= 5 s of waiting). */
static int _test_wr_wait_stalled(void) {
    size_t last = 0;
    int same = 0;
    for (int i = 0; i < 100; i++) {
        usleep(50000);
        size_t f = _test_fill();
        if (f > 0 && f == last) {
            if (++same >= 6) {
                return 1;
            }
        } else {
            same = 0;
        }
        last = f;
    }
    return 0;
}

/* Reads `count` S32 samples from fd and compares them with the ramp from
 * sample `from`. Returns the number of wrong samples, or -1 when the bytes
 * did not arrive (closed or timed out). */
static long _test_wr_read_ramp(int fd, size_t from, size_t count, int timeout_ms) {
    unsigned char *buf = malloc(count * 4);
    if (!buf) {
        return -1;
    }
    long bad = -1;
    if (_test_read_bytes(fd, buf, count * 4, timeout_ms) == 0) {
        bad = 0;
        for (size_t i = 0; i < count; i++) {
            int32_t v;
            memcpy(&v, buf + i * 4, 4);
            if (v != _test_f32_to_s32(_test_wr_ramp_f(from + i))) {
                bad++;
            }
        }
    }
    free(buf);
    return bad;
}

/* Captures the HTTP thread's trace lines (stderr at TRACE level 1) for one
 * case into a file; _test_trace_end restores stderr and returns the text. */
typedef struct {
    int  saved;
    int  old_level;
    char path[96];
} _test_trace_t;

static int _test_trace_begin(_test_trace_t *t) {
    fflush(stderr);
    t->saved = dup(2);
    snprintf(t->path, sizeof(t->path), "/tmp/fake-libpulse-trace-%d-XXXXXX", (int)getpid());
    int fd = mkstemp(t->path);
    if (t->saved < 0 || fd < 0) {
        return -1;
    }
    dup2(fd, 2);
    close(fd);
    t->old_level = g_debug_trace;
    g_debug_trace = 1;
    return 0;
}

static void _test_trace_end(_test_trace_t *t, char *out, size_t cap) {
    usleep(60000);   /* the HTTP thread's last line of the case */
    g_debug_trace = t->old_level;
    fflush(stderr);
    dup2(t->saved, 2);
    close(t->saved);
    FILE *f = fopen(t->path, "r");
    size_t n = f ? fread(out, 1, cap - 1, f) : 0;
    out[n] = '\0';
    if (f) {
        fclose(f);
    }
    unlink(t->path);
}

static void _test_wr_reset(void) {
    usleep(200000);
    _test_ring_reset();
    g_flush_disconnect = 0;
    g_departed_client_generation = NO_CLIENT_GENERATION;
}

/* ==================================================================== */
/* 79-37 D-31: gap hold -- harness cells                                */
/* ==================================================================== */

/* An attached /stream client: connect, GET, read the response header.
 * Returns the fd, -1 on failure. */
static int _test_hold_attach(int port) {
    static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
    int fd = _test_connect_loopback(port);
    if (fd < 0) {
        return -1;
    }
    if (write(fd, getReq, sizeof(getReq) - 1) < 0 || _test_read_header(fd, 3000) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Pushes `bytes` of the constant float `v` the way the daemon writes
 * (8192-byte pa_stream_write calls; the sample format of the test stream is
 * FLOAT32LE, so one float in is one S32 sample, 4 bytes, in the ring). */
static void _test_hold_push(pa_stream *s, size_t bytes, float v) {
    float buf[2048];
    for (int i = 0; i < 2048; i++) {
        buf[i] = v;
    }
    while (bytes > 0) {
        size_t n = bytes < 8192 ? bytes : 8192;
        pa_stream_write(s, buf, n, NULL, 0, 0);
        bytes -= n;
    }
}

/* Reads whatever arrives within window_ms and counts it; *eof = 1 when the
 * peer closed. Returns the byte count. */
static size_t _test_hold_read_window(int fd, int window_ms, int *eof) {
    unsigned char buf[65536];
    size_t total = 0;
    struct timeval start;
    gettimeofday(&start, NULL);
    if (eof) {
        *eof = 0;
    }
    while (_elapsed_ms(&start) < window_ms) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 10) > 0) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n == 0) {
                if (eof) *eof = 1;
                break;
            }
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                if (eof) *eof = 1;
                break;
            }
            total += (size_t)n;
        }
    }
    return total;
}

/* Reads until EOF (or max_ms); returns the byte count, *eof = 1 on EOF. */
static size_t _test_hold_read_to_eof(int fd, int max_ms, int *eof) {
    size_t total = 0;
    struct timeval start;
    gettimeofday(&start, NULL);
    *eof = 0;
    while (!*eof && _elapsed_ms(&start) < max_ms) {
        total += _test_hold_read_window(fd, 100, eof);
    }
    return total;
}

/* Leaves every cell with no client in the HTTP thread and a clean ring: a
 * plain POST /boundary closes a stale client at its next tick (nothing left to
 * pop up to the marker), then the ring and every marker are reset. */
static void _test_hold_cleanup(int port) {
    char b[512];
    (void)_test_post_control_body(port, "/boundary", b, sizeof(b));
    usleep(200000);
    _test_ring_reset();
    g_boundary_at_pushed = -1;
    g_seek_flush_armed = 0;
    g_flush_disconnect = 0;
    g_departed_client_generation = NO_CLIENT_GENERATION;
    setenv("SPOTON_FAKEPULSE_HOLD_GAP_MS", "0", 1);
    unsetenv("SPOTON_FAKEPULSE_HOLD_MS");
    atomic_store(&g_hold_test_clock_offset_ms, 0);
}

/* 79-37 D-31 archive cell: a natural title end with the measured shape
 * (8192-byte writes, a 536848-byte burst after a real 3 s gap, compiled
 * defaults) leaves zero bytes of the next title in the old stream, and the
 * next client starts at the burst's first byte. */
static void _test_hold_archive(pa_stream *s, int port, int *failures) {
    const size_t lenA = 705600;   /* 2 s of 0.25f: 86 x 8192 + 1088 */
    const size_t lenB = 536848;   /* the archive burst: 65 x 8192 + 4368 */
    unsetenv("SPOTON_FAKEPULSE_HOLD_GAP_MS");
    unsetenv("SPOTON_FAKEPULSE_HOLD_MS");
    _test_ring_reset();
    pthread_mutex_lock(&g_ring.lock);
    int64_t base = g_ring.total_pushed;
    pthread_mutex_unlock(&g_ring.lock);

    _test_trace_t tr;
    char trace[32768];
    trace[0] = '\0';
    int traced = (_test_trace_begin(&tr) == 0);
    int old_spike = g_boundary_spike;
    g_boundary_spike = 1;

    int gotA = 0, post_ok = 0, eof = 0, second_ok = 0;
    size_t leaked = 0, after = 0, second_n = 0, filled = 0;
    long bad = 0;
    char body[512];
    body[0] = '\0';
    int fd = _test_hold_attach(port);
    if (fd >= 0) {
        _test_hold_push(s, lenA, 0.25f);
        unsigned char *sink = malloc(lenA);
        gotA = (sink && _test_read_bytes(fd, sink, lenA, 8000) == 0);
        free(sink);
        if (gotA) {
            usleep(3000000);   /* the measured natural-end gap (2.9-3.1 s) */
            _test_hold_push(s, lenB, 0.5f);
            leaked = _test_hold_read_window(fd, 100, &eof);
            post_ok = _test_post_control_body(port, "/boundary?anchor=drain", body, sizeof(body));
            if (!eof) {
                after = _test_hold_read_to_eof(fd, 4000, &eof);
            }
            filled = _test_fill();
        }
        close(fd);
    }
    if (gotA) {
        int fd2 = _test_hold_attach(port);
        if (fd2 >= 0) {
            unsigned char *sb = malloc(lenB);
            if (sb && _test_read_bytes(fd2, sb, lenB, 5000) == 0) {
                int32_t want = _test_f32_to_s32(0.5f);
                for (size_t i = 0; i + 3 < lenB; i += 4) {
                    int32_t v;
                    memcpy(&v, sb + i, 4);
                    if (v != want) bad++;
                }
                second_n = lenB;
            }
            free(sb);
            close(fd2);
        }
        second_ok = (second_n == lenB && bad == 0);
    }
    if (traced) {
        _test_trace_end(&tr, trace, sizeof(trace));
    }
    g_boundary_spike = old_spike;

    char via[16], anchor[16], hold[16];
    _test_body_str(body, "via=", via, sizeof(via));
    _test_body_str(body, "anchor=", anchor, sizeof(anchor));
    _test_body_str(body, "hold=", hold, sizeof(hold));
    long long boundary = _test_body_i64(body, "boundary=");
    long long hold_at  = _test_body_i64(body, "hold_at=");
    long long P = (long long)base + (long long)lenA;
    char k1[64], k2[64], k3[64], k4[128];
    snprintf(k1, sizeof(k1), "hold_armed: at=%lld ", P);
    snprintf(k2, sizeof(k2), "hold_consumed: at=%lld ", P);
    snprintf(k3, sizeof(k3), "hold=consumed hold_at=%lld\n", P);
    snprintf(k4, sizeof(k4), "wrote=0 total_popped=%lld boundary=%lld trimmed=0", P, P);
    int t1 = strstr(trace, k1) != NULL, t2 = strstr(trace, k2) != NULL;
    int t3 = strstr(trace, k3) != NULL, t4 = strstr(trace, k4) != NULL
             && strstr(trace, "boundary_reached: closing client fd=") != NULL;
    int ok = fd >= 0 && gotA && leaked == 0 && post_ok && strcmp(via, "live") == 0
          && strcmp(anchor, "drain") == 0 && strcmp(hold, "consumed") == 0
          && boundary == P && hold_at == P && eof && after == 0 && filled == lenB
          && second_ok && t1 && t2 && t3 && t4;
    if (!ok) {
        fprintf(stderr, "FAIL: hold: archive natural end leaves zero bytes of the next title in the old stream: attached=%d gotA=%d leaked=%zu (want 0) post_ok=%d via='%s' anchor='%s' (want drain) hold='%s' (want consumed) boundary=%lld hold_at=%lld (want %lld) eof=%d after=%zu (want 0) fill_after=%zu (want %zu) second_client=%zu bytes bad=%ld trace[armed=%d consumed=%d planted=%d reached=%d]\n",
                fd >= 0, gotA, leaked, post_ok, via, anchor, hold, boundary, hold_at, P, eof, after, filled, lenB, second_n, bad, t1, t2, t3, t4);
        (*failures)++;
    } else {
        printf("ok: hold: archive natural end leaves zero bytes of the next title in the old stream (3 s gap, %zu B burst withheld, boundary=hold_at=%lld, old stream got exactly %zu B, next client started at the burst's first byte)\n",
               lenB, P, lenA);
    }
    _test_hold_cleanup(port);
}

/* ---- 79-37 D-31 cells (timeout, flushes, fresh client, steady, release, plain POST, off-loopback, gap 0, negative clock) ---- */

typedef struct {
    int     fd;
    int64_t base;   /* total_pushed at the cell start */
    int     gotA;   /* the title A was pushed and the client read all of it */
} _test_hc_t;

#define _TEST_HOLD_LEN_A 352800   /* 1 s of 0.25f */
#define _TEST_HOLD_LEN_B 536848   /* the archive burst */

static void _test_hold_state(int64_t *hold_at, int64_t *armed, char *reason, size_t cap) {
    pthread_mutex_lock(&g_ring.lock);
    *hold_at = g_ring.hold_at;
    *armed = g_ring.hold_armed_total;
    snprintf(reason, cap, "%s", g_ring.hold_last_release);
    pthread_mutex_unlock(&g_ring.lock);
}

/* Starts a cell: knobs, a clean ring, an attached client that has read all of
 * title A (so the ring was emptied by that client's pop and the empty clock
 * runs). */
static void _test_hold_open(pa_stream *s, int port, const char *gap, const char *holdms, _test_hc_t *c) {
    memset(c, 0, sizeof(*c));
    c->fd = -1;
    setenv("SPOTON_FAKEPULSE_HOLD_GAP_MS", gap, 1);
    if (holdms) {
        setenv("SPOTON_FAKEPULSE_HOLD_MS", holdms, 1);
    } else {
        unsetenv("SPOTON_FAKEPULSE_HOLD_MS");
    }
    _test_ring_reset();
    pthread_mutex_lock(&g_ring.lock);
    c->base = g_ring.total_pushed;
    pthread_mutex_unlock(&g_ring.lock);
    c->fd = _test_hold_attach(port);
    if (c->fd < 0) {
        return;
    }
    _test_hold_push(s, _TEST_HOLD_LEN_A, 0.25f);
    unsigned char *sink = malloc(_TEST_HOLD_LEN_A);
    c->gotA = (sink && _test_read_bytes(c->fd, sink, _TEST_HOLD_LEN_A, 8000) == 0);
    free(sink);
}

/* Reads until `want` bytes or max_ms. *first_ms = ms from the call to the
 * first byte (-1 = none); out (optional) receives the bytes. */
static size_t _test_hold_collect(int fd, int max_ms, size_t want, unsigned char *out, long *first_ms, int *eof) {
    unsigned char tmp[65536];
    size_t total = 0;
    struct timeval start;
    gettimeofday(&start, NULL);
    *first_ms = -1;
    *eof = 0;
    while (total < want && _elapsed_ms(&start) < max_ms) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, 5) > 0) {
            size_t room = want - total;
            if (room > sizeof(tmp)) room = sizeof(tmp);
            ssize_t n = read(fd, tmp, room);
            if (n == 0) { *eof = 1; break; }
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                *eof = 1;
                break;
            }
            if (*first_ms < 0) *first_ms = _elapsed_ms(&start);
            if (out) memcpy(out + total, tmp, (size_t)n);
            total += (size_t)n;
        }
    }
    return total;
}

static long _test_hold_bad_samples(const unsigned char *b, size_t n, float v) {
    long bad = 0;
    int32_t want = _test_f32_to_s32(v);
    for (size_t i = 0; i + 3 < n; i += 4) {
        int32_t x;
        memcpy(&x, b + i, 4);
        if (x != want) bad++;
    }
    return bad;
}

static void _test_hold_verdict(int *failures, int ok, const char *name, const char *facts) {
    if (ok) {
        printf("ok: %s (%s)\n", name, facts);
    } else {
        fprintf(stderr, "FAIL: %s: %s\n", name, facts);
        (*failures)++;
    }
}

static void _test_hold_timeout(pa_stream *s, int port, int *failures) {
    const char *name = "hold: without a POST the hold times out and the held bytes are served, none lost";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "300", &c);
    long first = -1;
    int eof = 0;
    size_t got = 0;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        got = _test_hold_collect(c.fd, 2000, _TEST_HOLD_LEN_B, NULL, &first, &eof);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d first_byte_ms=%ld (want 240..800) got=%zu (want %d) armed=%lld (want 1) hold_at=%lld release='%s' (want timeout)",
             c.gotA, first, got, _TEST_HOLD_LEN_B, (long long)armed, (long long)hold_at, reason);
    int ok = c.gotA && first >= 240 && first <= 800 && got == _TEST_HOLD_LEN_B && armed == 1
          && hold_at == -1 && strcmp(reason, "timeout") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_flush_armed(pa_stream *s, int port, int *failures) {
    const char *name = "hold: an armed flush clears the hold and the kept client gets only post-flush bytes";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_hold_open(s, port, "100", "2000", &c);
    size_t leaked = 0, got = 0, extra = 0;
    long first = -1, bad = -1;
    int eof = 0, eof2 = 0, armpost = 0;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        leaked = _test_hold_read_window(c.fd, 60, &eof2);
        armpost = _test_post_control(port, "/seek-arm");
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        _test_hold_push(s, lenC, 0.75f);
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 1500, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
        extra = _test_hold_read_window(c.fd, 150, &eof2);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d leaked_before_flush=%zu (want 0) arm_post=%d got=%zu (want %zu) bad_samples=%ld (want 0) first_byte_ms=%ld (want <= 250) extra=%zu (want 0) eof=%d%d hold_at=%lld release='%s' (want flush)",
             c.gotA, leaked, armpost, got, lenC, bad, first, extra, eof, eof2, (long long)hold_at, reason);
    int ok = c.gotA && leaked == 0 && armpost && got == lenC && bad == 0 && first >= 0 && first <= 250
          && extra == 0 && !eof && !eof2 && hold_at == -1 && strcmp(reason, "flush") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_flush_unarmed(pa_stream *s, int port, int *failures) {
    const char *name = "hold: an unarmed flush clears the hold and the departing client gets no byte of the next title";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "2000", &c);
    size_t leaked = 0, after = 0;
    int eof = 0, eof2 = 0;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        leaked = _test_hold_read_window(c.fd, 60, &eof2);
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        after = _test_hold_read_to_eof(c.fd, 3000, &eof);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d leaked_before_flush=%zu (want 0) eof=%d after_flush=%zu (want 0) hold_at=%lld release='%s' (want flush)",
             c.gotA, leaked, eof, after, (long long)hold_at, reason);
    int ok = c.gotA && leaked == 0 && !eof2 && eof && after == 0 && hold_at == -1 && strcmp(reason, "flush") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_fresh_client(pa_stream *s, int port, int *failures) {
    const char *name = "hold: a fresh client is never held";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "300", &c);
    int fd2 = -1;
    long first = -1;
    int eof = 0;
    size_t got = 0;
    if (c.gotA) {
        usleep(150000);
        fd2 = _test_hold_attach(port);   /* takeover: client 1 is closed by the shim */
        usleep(100000);
        if (fd2 >= 0) {
            _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
            got = _test_hold_collect(fd2, 2000, _TEST_HOLD_LEN_B, NULL, &first, &eof);
        }
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d client2=%d first_byte_ms=%ld (want <= 250) got=%zu (want %d) armed=%lld (want 0)",
             c.gotA, fd2 >= 0, first, got, _TEST_HOLD_LEN_B, (long long)armed);
    int ok = c.gotA && fd2 >= 0 && first >= 0 && first <= 250 && got == _TEST_HOLD_LEN_B && armed == 0;
    if (c.fd >= 0) close(c.fd);
    if (fd2 >= 0) close(fd2);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_steady(pa_stream *s, int port, int *failures) {
    const char *name = "hold: steady playback never arms a hold";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "300", &c);
    size_t received = 0, pushed = 0;
    int eof = 0;
    if (c.gotA) {
        for (int i = 0; i < 100; i++) {
            _test_hold_push(s, 8192, 0.25f);
            pushed += 8192;
            received += _test_hold_read_window(c.fd, 20, &eof);
        }
        received += _test_hold_read_window(c.fd, 300, &eof);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d pushed=%zu received=%zu armed=%lld (want 0) hold_at=%lld",
             c.gotA, pushed, received, (long long)armed, (long long)hold_at);
    int ok = c.gotA && pushed == 819200 && received == pushed && armed == 0 && hold_at == -1;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_release_active(pa_stream *s, int port, int *failures) {
    const char *name = "hold: POST /hold-release releases an active hold at once";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "3000", &c);
    size_t leaked = 0, got = 0;
    long first = -1;
    int eof = 0, eof2 = 0, post_ok = 0;
    char body[512];
    body[0] = '\0';
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        leaked = _test_hold_read_window(c.fd, 50, &eof2);
        post_ok = _test_post_control_body(port, "/hold-release", body, sizeof(body));
        got = _test_hold_collect(c.fd, 2500, _TEST_HOLD_LEN_B, NULL, &first, &eof);
    }
    char hold[16];
    _test_body_str(body, "hold=", hold, sizeof(hold));
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d leaked_before=%zu (want 0) post_ok=%d hold='%s' (want released) first_byte_ms=%ld (want <= 250) got=%zu (want %d) hold_at=%lld release='%s' (want release)",
             c.gotA, leaked, post_ok, hold, first, got, _TEST_HOLD_LEN_B, (long long)hold_at, reason);
    int ok = c.gotA && leaked == 0 && post_ok && strcmp(hold, "released") == 0 && first >= 0 && first <= 250
          && got == _TEST_HOLD_LEN_B && hold_at == -1 && strcmp(reason, "release") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_release_before_refill(pa_stream *s, int port, int *failures) {
    const char *name = "hold: POST /hold-release before the refill suppresses the next arming";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "300", &c);
    size_t got = 0;
    long first = -1;
    int eof = 0, post_ok = 0;
    char body[512];
    body[0] = '\0';
    if (c.gotA) {
        usleep(150000);
        post_ok = _test_post_control_body(port, "/hold-release", body, sizeof(body));
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        got = _test_hold_collect(c.fd, 2000, _TEST_HOLD_LEN_B, NULL, &first, &eof);
    }
    char hold[16];
    _test_body_str(body, "hold=", hold, sizeof(hold));
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d post_ok=%d hold='%s' (want suppressed) first_byte_ms=%ld (want <= 250) got=%zu (want %d) armed=%lld (want 0)",
             c.gotA, post_ok, hold, first, got, _TEST_HOLD_LEN_B, (long long)armed);
    int ok = c.gotA && post_ok && strcmp(hold, "suppressed") == 0 && first >= 0 && first <= 250
          && got == _TEST_HOLD_LEN_B && armed == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_plain_post(pa_stream *s, int port, int *failures) {
    const char *name = "hold: a plain POST /boundary releases the hold and plants at total_pushed";
    _test_hc_t c;
    _test_hold_open(s, port, "100", "1000", &c);
    size_t leaked = 0, after = 0;
    int eof = 0, eof2 = 0, post_ok = 0;
    char body[512];
    body[0] = '\0';
    int64_t pushed_end = -1;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        leaked = _test_hold_read_window(c.fd, 50, &eof2);
        pthread_mutex_lock(&g_ring.lock);
        pushed_end = g_ring.total_pushed;
        pthread_mutex_unlock(&g_ring.lock);
        post_ok = _test_post_control_body(port, "/boundary", body, sizeof(body));
        after = _test_hold_read_to_eof(c.fd, 4000, &eof);
    }
    char anchor[16], hold[16];
    _test_body_str(body, "anchor=", anchor, sizeof(anchor));
    _test_body_str(body, "hold=", hold, sizeof(hold));
    long long boundary = _test_body_i64(body, "boundary=");
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d leaked_before=%zu (want 0) post_ok=%d anchor='%s' (want pushed) hold='%s' (want plain) boundary=%lld (want %lld) eof=%d after=%zu (want %d) release='%s' (want plain)",
             c.gotA, leaked, post_ok, anchor, hold, boundary, (long long)pushed_end, eof, after, _TEST_HOLD_LEN_B, reason);
    int ok = c.gotA && leaked == 0 && post_ok && strcmp(anchor, "pushed") == 0 && strcmp(hold, "plain") == 0
          && boundary == (long long)pushed_end && eof && after == _TEST_HOLD_LEN_B && strcmp(reason, "plain") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_off_loopback(pa_stream *s, int port, int *failures) {
    const char *name = "hold: POST /hold-release is refused off-loopback";
    struct ifaddrs *ifa0 = NULL, *ifa;
    struct in_addr lan;
    int haveLan = 0;
    if (getifaddrs(&ifa0) == 0) {
        for (ifa = ifa0; ifa && !haveLan; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET && (ifa->ifa_flags & IFF_UP)
                && !(ifa->ifa_flags & IFF_LOOPBACK)) {
                lan = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr;
                haveLan = 1;
            }
        }
        freeifaddrs(ifa0);
    }
    if (!haveLan) {
        printf("skip: %s (no non-loopback IPv4 address on this host; the loopback guard is the first statement of the handler)\n", name);
        return;
    }
    _test_hc_t c;
    _test_hold_open(s, port, "100", "3000", &c);
    int64_t at0 = -2, at1 = -3, armed;
    char reason[16], lresp[128];
    lresp[0] = '\0';
    size_t llen = 0;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        _test_hold_state(&at0, &armed, reason, sizeof(reason));
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in la;
        memset(&la, 0, sizeof(la));
        la.sin_family = AF_INET;
        la.sin_addr = lan;
        la.sin_port = htons((uint16_t)port);
        if (lfd >= 0 && connect(lfd, (struct sockaddr *)&la, sizeof(la)) == 0) {
            static const char lreq[] = "POST /hold-release HTTP/1.0\r\nConnection: close\r\n\r\n";
            if (write(lfd, lreq, sizeof(lreq) - 1) > 0) {
                for (int i = 0; i < 30 && llen < sizeof(lresp) - 1; i++) {
                    struct pollfd lp;
                    lp.fd = lfd;
                    lp.events = POLLIN;
                    if (poll(&lp, 1, 100) > 0) {
                        ssize_t n = read(lfd, lresp + llen, sizeof(lresp) - 1 - llen);
                        if (n <= 0) break;
                        llen += (size_t)n;
                    }
                }
            }
        }
        lresp[llen] = '\0';
        if (lfd >= 0) close(lfd);
        _test_hold_state(&at1, &armed, reason, sizeof(reason));
    }
    int l403 = (strncmp(lresp, "HTTP/1.0 403", 12) == 0);
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d answer 403=%d (%.12s) hold_at before=%lld after=%lld (want equal and >= 0)",
             c.gotA, l403, lresp, (long long)at0, (long long)at1);
    int ok = c.gotA && l403 && at0 >= 0 && at0 == at1;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_gap_zero(pa_stream *s, int port, int *failures) {
    const char *name = "hold: HOLD_GAP_MS 0 turns the hold off";
    _test_hc_t c;
    _test_hold_open(s, port, "0", "300", &c);
    size_t got = 0;
    long first = -1;
    int eof = 0;
    if (c.gotA) {
        usleep(600000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        got = _test_hold_collect(c.fd, 2000, _TEST_HOLD_LEN_B, NULL, &first, &eof);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d first_byte_ms=%ld (want <= 250) got=%zu (want %d) armed=%lld (want 0)",
             c.gotA, first, got, _TEST_HOLD_LEN_B, (long long)armed);
    int ok = c.gotA && first >= 0 && first <= 250 && got == _TEST_HOLD_LEN_B && armed == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_hold_negative_clock(pa_stream *s, int port, int *failures) {
    const char *name = "hold: the hold arms when the monotonic clock reads negative (32-bit wrap)";
    atomic_store(&g_hold_test_clock_offset_ms, -4100000000000LL);   /* _hold_now_ms() reads about -4.1e12 for the whole cell */
    _test_hc_t c;
    _test_hold_open(s, port, "100", "300", &c);
    size_t leaked = 0, after = 0;
    int eof = 0, eof2 = 0, post_ok = 0;
    int64_t armed_after_push = -1;
    char body[512];
    body[0] = '\0';
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        int64_t h0;
        char r0[16];
        _test_hold_state(&h0, &armed_after_push, r0, sizeof(r0));
        leaked = _test_hold_read_window(c.fd, 100, &eof2);
        post_ok = _test_post_control_body(port, "/boundary?anchor=drain", body, sizeof(body));
        after = _test_hold_read_to_eof(c.fd, 3000, &eof);
    }
    int64_t now_probe = _hold_now_ms();
    char hold[16];
    _test_body_str(body, "hold=", hold, sizeof(hold));
    long long hold_at = _test_body_i64(body, "hold_at=");
    long long want_at = (long long)c.base + (long long)_TEST_HOLD_LEN_A;
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d clock_now=%lld (want < 0) armed=%lld (want 1) leaked=%zu (want 0) post_ok=%d hold='%s' (want consumed) hold_at=%lld (want %lld) eof=%d after=%zu (want 0)",
             c.gotA, (long long)now_probe, (long long)armed_after_push, leaked, post_ok, hold, hold_at, want_at, eof, after);
    int ok = c.gotA && now_probe < 0 && armed_after_push == 1 && leaked == 0 && post_ok
          && strcmp(hold, "consumed") == 0 && hold_at == want_at && eof && after == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    atomic_store(&g_hold_test_clock_offset_ms, 0);
    _test_hold_cleanup(port);
}

/* ==================================================================== */
/* 79-47 (D-34): browse keep -- harness cells                           */
/* ==================================================================== */
/* An app seek (and an app next/previous before Control redirects it) makes
 * the daemon flush on its own while LMS's stream is a browse title. Unarmed,
 * that flush closed LMS's client and LMS played the next item. With POST
 * /browse-keep?on=1 such a flush keeps the client; Control's own title
 * changes (the drain POST /boundary, a new GET /stream) still end the old
 * stream. These cells only reach the shim through its HTTP endpoint, so they
 * compile against a shim without the endpoint (RED). */

/* POSTs /browse-keep?on=<v> and copies the reply body; returns 1 on a 200
 * with a body. */
static int _test_browse_keep_post(int port, const char *query, char *body, size_t cap) {
    char path[64];
    snprintf(path, sizeof(path), "/browse-keep%s", query);
    return _test_post_control_body(port, path, body, cap);
}

static void _test_browse_cleanup(int port) {
    char b[128];
    (void)_test_browse_keep_post(port, "?on=0", b, sizeof(b));
    _test_hold_cleanup(port);
}

/* S1: keep set, the daemon flushes on its own (no arm): the client stays and
 * gets exactly the post-flush bytes; the held refill of the old position is
 * dropped with the flush, as on the armed path. */
static void _test_browse_keep_flush(pa_stream *s, int port, int *failures) {
    const char *name = "browse: with browse keep set an unarmed flush keeps the client and it gets only post-flush bytes";
    const size_t lenC = 32768;
    char kb[128];
    kb[0] = '\0';
    int keep_ok = _test_browse_keep_post(port, "?on=1", kb, sizeof(kb));
    _test_hc_t c;
    _test_hold_open(s, port, "100", "2000", &c);
    size_t leaked = 0, got = 0, extra = 0;
    long first = -1, bad = -1;
    int eof = 0, eof2 = 0, fd_flag = -1, armed_after = -1;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        leaked = _test_hold_read_window(c.fd, 60, &eof2);
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        fd_flag = (int)g_flush_disconnect;
        armed_after = (int)g_seek_flush_armed;
        _test_hold_push(s, lenC, 0.75f);
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 1500, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
        extra = _test_hold_read_window(c.fd, 300, &eof2);
    }
    int64_t hold_at, armed;
    char reason[16];
    _test_hold_state(&hold_at, &armed, reason, sizeof(reason));
    char facts[512];
    snprintf(facts, sizeof(facts), "keep_post=%d body='%.20s' (want browse_keep=1) gotA=%d leaked=%zu (want 0) flush_disconnect=%d (want 0) seek_armed=%d (want 0) got=%zu (want %zu) bad_samples=%ld (want 0) first_byte_ms=%ld (want <= 250) extra=%zu (want 0) eof=%d%d (want 00) release='%s' (want flush)",
             keep_ok, kb, c.gotA, leaked, fd_flag, armed_after, got, lenC, bad, first, extra, eof, eof2, reason);
    int ok = keep_ok && strncmp(kb, "browse_keep=1", 13) == 0 && c.gotA && leaked == 0 && fd_flag == 0
          && armed_after == 0 && got == lenC && bad == 0 && first >= 0 && first <= 250 && extra == 0
          && !eof && !eof2 && strcmp(reason, "flush") == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

/* S2: without keep (never set, and set then cleared) an unarmed flush closes
 * the client exactly as before 79-47. */
static void _test_browse_default_flush(pa_stream *s, int port, int *failures) {
    const char *name = "browse: without browse keep an unarmed flush still closes the client (never set, and after on=0)";
    int eof_a = 0, eof_b = 0, off_ok = 0, on_ok = 0;
    size_t after_a = 99, after_b = 99;
    char ob[128], nb[128];
    ob[0] = nb[0] = '\0';
    _test_hc_t c;
    /* leg a: never set */
    _test_hold_open(s, port, "0", NULL, &c);
    int gotA_a = c.gotA;
    if (c.gotA) {
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        after_a = _test_hold_read_to_eof(c.fd, 3000, &eof_a);
    }
    if (c.fd >= 0) close(c.fd);
    _test_browse_cleanup(port);
    /* leg b: on, then off */
    on_ok = _test_browse_keep_post(port, "?on=1", nb, sizeof(nb));
    off_ok = _test_browse_keep_post(port, "?on=0", ob, sizeof(ob));
    _test_hold_open(s, port, "0", NULL, &c);
    int gotA_b = c.gotA;
    if (c.gotA) {
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        after_b = _test_hold_read_to_eof(c.fd, 3000, &eof_b);
    }
    if (c.fd >= 0) close(c.fd);
    char facts[512];
    snprintf(facts, sizeof(facts), "never_set: gotA=%d eof=%d (want 1) after=%zu (want 0); on_off: on_post=%d body='%.20s' off_post=%d body='%.20s' (want browse_keep=0) gotA=%d eof=%d (want 1) after=%zu (want 0)",
             gotA_a, eof_a, after_a, on_ok, nb, off_ok, ob, gotA_b, eof_b, after_b);
    int ok = gotA_a && eof_a && after_a == 0 && on_ok && off_ok && strncmp(ob, "browse_keep=0", 13) == 0
          && gotA_b && eof_b && after_b == 0;
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

/* S3a: keep set, a natural title end: the gap hold arms and Control's drain
 * POST /boundary ends the old stream at the old title's last byte. */
static void _test_browse_keep_drain(pa_stream *s, int port, int *failures) {
    const char *name = "browse: with browse keep set the drain POST /boundary still ends the title and the gap hold applies";
    char kb[128], body[512];
    kb[0] = body[0] = '\0';
    int keep_ok = _test_browse_keep_post(port, "?on=1", kb, sizeof(kb));
    _test_hc_t c;
    _test_hold_open(s, port, "100", "2000", &c);
    size_t leaked = 0, after = 0;
    int eof = 0, eof2 = 0, post_ok = 0;
    int64_t armed_after_push = -1;
    if (c.gotA) {
        usleep(150000);
        _test_hold_push(s, _TEST_HOLD_LEN_B, 0.5f);
        int64_t h0;
        char r0[16];
        _test_hold_state(&h0, &armed_after_push, r0, sizeof(r0));
        leaked = _test_hold_read_window(c.fd, 100, &eof2);
        post_ok = _test_post_control_body(port, "/boundary?anchor=drain", body, sizeof(body));
        after = _test_hold_read_to_eof(c.fd, 3000, &eof);
    }
    char via[16], hold[16];
    _test_body_str(body, "via=", via, sizeof(via));
    _test_body_str(body, "hold=", hold, sizeof(hold));
    long long hold_at = _test_body_i64(body, "hold_at=");
    long long want_at = (long long)c.base + (long long)_TEST_HOLD_LEN_A;
    char facts[512];
    snprintf(facts, sizeof(facts), "keep_post=%d gotA=%d hold_armed=%lld (want 1) leaked=%zu (want 0) post_ok=%d via='%s' (want live) hold='%s' (want consumed) hold_at=%lld (want %lld) eof=%d (want 1) after=%zu (want 0)",
             keep_ok, c.gotA, (long long)armed_after_push, leaked, post_ok, via, hold, hold_at, want_at, eof, after);
    int ok = keep_ok && c.gotA && armed_after_push == 1 && leaked == 0 && !eof2 && post_ok
          && strcmp(via, "live") == 0 && strcmp(hold, "consumed") == 0 && hold_at == want_at && eof && after == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

/* S3b: keep set, Control's own title change through LMS (a new GET /stream):
 * the old client is superseded, the new one gets the new bytes. */
static void _test_browse_keep_takeover(pa_stream *s, int port, int *failures) {
    const char *name = "browse: with browse keep set a new GET /stream still supersedes the old client";
    const size_t lenC = 32768;
    char kb[128];
    kb[0] = '\0';
    int keep_ok = _test_browse_keep_post(port, "?on=1", kb, sizeof(kb));
    _test_hc_t c;
    _test_hold_open(s, port, "0", NULL, &c);
    int old_eof = 0, eof = 0, fd2 = -1;
    size_t got = 0;
    long first = -1, bad = -1;
    if (c.gotA) {
        fd2 = _test_hold_attach(port);
        old_eof = _test_saw_eof(c.fd, 1500);
        if (fd2 >= 0) {
            _test_hold_push(s, lenC, 0.75f);
            unsigned char *buf = malloc(lenC);
            got = _test_hold_collect(fd2, 1500, lenC, buf, &first, &eof);
            bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
            free(buf);
        }
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "keep_post=%d gotA=%d new_attached=%d old_eof=%d (want 1) new_got=%zu (want %zu) bad_samples=%ld (want 0) eof=%d (want 0)",
             keep_ok, c.gotA, fd2 >= 0, old_eof, got, lenC, bad, eof);
    int ok = keep_ok && c.gotA && fd2 >= 0 && old_eof && got == lenC && bad == 0 && !eof;
    if (c.fd >= 0) close(c.fd);
    if (fd2 >= 0) close(fd2);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

/* S4: keep set, the connect /seek-arm path: the arm is consumed by the flush
 * (not left standing to close the drain gate), the client is kept. */
static void _test_browse_keep_armed(pa_stream *s, int port, int *failures) {
    const char *name = "browse: with browse keep set an armed flush consumes the arm and keeps the client";
    const size_t lenC = 32768;
    char kb[128];
    kb[0] = '\0';
    int keep_ok = _test_browse_keep_post(port, "?on=1", kb, sizeof(kb));
    _test_hc_t c;
    _test_hold_open(s, port, "0", NULL, &c);
    int armpost = 0, eof = 0, armed_after = -1;
    size_t got = 0;
    long first = -1, bad = -1;
    if (c.gotA) {
        armpost = _test_post_control(port, "/seek-arm");
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        armed_after = (int)g_seek_flush_armed;
        _test_hold_push(s, lenC, 0.75f);
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 1500, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "keep_post=%d gotA=%d arm_post=%d seek_armed_after=%d (want 0) got=%zu (want %zu) bad_samples=%ld (want 0) first_byte_ms=%ld (want <= 250) eof=%d (want 0)",
             keep_ok, c.gotA, armpost, armed_after, got, lenC, bad, first, eof);
    int ok = keep_ok && c.gotA && armpost && armed_after == 0 && got == lenC && bad == 0
          && first >= 0 && first <= 250 && !eof;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

/* S5: a POST without on=0|1 is refused (400) and changes nothing: an unarmed
 * flush afterwards still closes the client. */
static void _test_browse_keep_bad(pa_stream *s, int port, int *failures) {
    const char *name = "browse: a POST /browse-keep without on=0 or on=1 is refused and changes nothing";
    int fd = _test_post_raw(port, "/browse-keep");
    char resp[128];
    size_t rlen = 0;
    if (fd >= 0) {
        struct timeval start;
        gettimeofday(&start, NULL);
        while (rlen < sizeof(resp) - 1 && _elapsed_ms(&start) < 1500) {
            struct pollfd pfd; pfd.fd = fd; pfd.events = POLLIN;
            if (poll(&pfd, 1, 50) > 0) {
                ssize_t n = read(fd, resp + rlen, sizeof(resp) - 1 - rlen);
                if (n <= 0) break;
                rlen += (size_t)n;
            }
        }
        close(fd);
    }
    resp[rlen] = '\0';
    int refused = strncmp(resp, "HTTP/1.0 400 ", 13) == 0;
    _test_hc_t c;
    _test_hold_open(s, port, "0", NULL, &c);
    int eof = 0;
    size_t after = 99;
    if (c.gotA) {
        pa_operation *op = pa_stream_flush(s, NULL, NULL);
        if (op) {
            pa_operation_unref(op);
        }
        after = _test_hold_read_to_eof(c.fd, 3000, &eof);
    }
    char facts[256];
    snprintf(facts, sizeof(facts), "reply='%.15s' (want HTTP/1.0 400) gotA=%d eof=%d (want 1) after=%zu (want 0)",
             resp, c.gotA, eof, after);
    int ok = refused && c.gotA && eof && after == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
}

static void _test_browse_cases(pa_stream *s, int port, int *failures) {
    _test_browse_keep_flush(s, port, failures);
    _test_browse_default_flush(s, port, failures);
    _test_browse_keep_drain(s, port, failures);
    _test_browse_keep_takeover(s, port, failures);
    _test_browse_keep_armed(s, port, failures);
    _test_browse_keep_bad(s, port, failures);
}

/* ==================================================================== */
/* 79-50 (D-34 R2): the connect decision window -- harness cells        */
/* ==================================================================== */
/* In a Connect session an app seek makes the daemon flush on its own. The
 * flush is unarmed, so the shim used to close LMS's stream at the next tick,
 * before Control (which learns the flush was a seek from the daemon's first
 * frame, 6-7 ms later) could say so (79-47 R2, R2_3: close 9 ms after the
 * flush). With SPOTON_FAKEPULSE_FLUSH_DECIDE_MS (the window, default 2000)
 * the shim holds an unarmed flush-disconnect open, withholds the post-flush
 * audio, and decides at the first signal: POST /seek-keep keeps the client,
 * POST /boundary (the skip) or the deadline closes it. These cells only reach
 * the shim through its HTTP endpoints, the env knob and pa_stream_flush, so
 * they compile against a shim without the window (RED). Every cell sets its
 * own window and restores 0 (the contract of every older cell). */

static void _test_connect_cleanup(int port) {
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", "0", 1);
    _test_hold_cleanup(port);
}

/* A clean ring, an attached client that read all of title A, the window set. */
static void _test_connect_open(pa_stream *s, int port, const char *window_ms, _test_hc_t *c) {
    _test_hold_open(s, port, "0", NULL, c);
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", window_ms, 1);
}

static void _test_connect_flush(pa_stream *s) {
    pa_operation *op = pa_stream_flush(s, NULL, NULL);
    if (op) {
        pa_operation_unref(op);
    }
}

/* ms from t0 until the peer's EOF (10 ms granularity), counting the bytes that
 * arrive meanwhile into *bytes; -1 when there is no EOF within max_ms. */
static long _test_connect_eof_ms(int fd, const struct timeval *t0, int max_ms, size_t *bytes) {
    int eof = 0;
    while (_elapsed_ms(t0) < max_ms) {
        size_t n = _test_hold_read_window(fd, 10, &eof);
        if (bytes) {
            *bytes += n;
        }
        if (eof) {
            return _elapsed_ms(t0);
        }
    }
    return -1;
}

/* C1: a keep inside the window keeps the client; it gets exactly the post-flush bytes and stays open past the deadline. */
static void _test_connect_c1(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C1 a keep inside the decision window keeps the client and it gets the post-flush bytes";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    char body[128];
    body[0] = '\0';
    int keep_ok = 0, eof_pre = 0, eof = 0, eof2 = 0;
    size_t pre = 0, got = 0, extra = 0;
    long first = -1, bad = -1;
    if (c.gotA) {
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        pre = _test_hold_read_window(c.fd, 120, &eof_pre);
        keep_ok = _test_post_control_body(port, "/seek-keep", body, sizeof(body));
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 1500, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
        extra = _test_hold_read_window(c.fd, 1100, &eof2);   /* past the 1000 ms deadline */
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d held_before_keep=%zu eof_before_keep=%d (want 0 and 0) keep_post=%d body='%.16s' (want seek_keep=1) got=%zu (want %zu) bad_samples=%ld (want 0) first_byte_ms=%ld (want <= 250) extra=%zu eof=%d%d (want 00)",
             c.gotA, pre, eof_pre, keep_ok, body, got, lenC, bad, first, extra, eof, eof2);
    int ok = c.gotA && pre == 0 && !eof_pre && keep_ok && strncmp(body, "seek_keep=1", 11) == 0
          && got == lenC && bad == 0 && first >= 0 && first <= 250 && extra == 0 && !eof && !eof2;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C2: POST /boundary inside the window (the skip) ends it at once: the old client gets EOF and none of the next title. */
static void _test_connect_c2(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C2 a boundary inside the decision window closes the old client at once with no byte of the next title";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    char body[512], via[16];
    body[0] = via[0] = '\0';
    int post_ok = 0, eof_pre = 0;
    size_t pre = 0, after = 0;
    long ms = -1;
    if (c.gotA) {
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        pre = _test_hold_read_window(c.fd, 110, &eof_pre);
        post_ok = _test_post_control_body(port, "/boundary", body, sizeof(body));
        struct timeval tr;
        gettimeofday(&tr, NULL);
        ms = _test_connect_eof_ms(c.fd, &tr, 600, &after);
        _test_body_str(body, "via=", via, sizeof(via));
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d held_before_boundary=%zu eof_before_boundary=%d (want 0 and 0) post_ok=%d via='%s' (want departed) eof_after_reply_ms=%ld (want 0..100) bytes_after=%zu (want 0)",
             c.gotA, pre, eof_pre, post_ok, via, ms, after);
    int ok = c.gotA && pre == 0 && !eof_pre && post_ok && strcmp(via, "departed") == 0
          && ms >= 0 && ms <= 100 && after == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C3: no signal at all: the window fails safe to today's close at its deadline, nothing of the next title on the old client. */
static void _test_connect_c3(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C3 with no signal the window closes the client at its deadline and withholds the next title";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "300", &c);
    size_t bytes = 0;
    long ms = -1;
    if (c.gotA) {
        struct timeval t0;
        gettimeofday(&t0, NULL);
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        ms = _test_connect_eof_ms(c.fd, &t0, 1500, &bytes);
    }
    char facts[256];
    snprintf(facts, sizeof(facts), "gotA=%d eof_after_flush_ms=%ld (want 250..450) bytes=%zu (want 0)", c.gotA, ms, bytes);
    int ok = c.gotA && ms >= 250 && ms <= 450 && bytes == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C4: the boundary's decision is final: a keep after it is refused and the client still ends. */
static void _test_connect_c4(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C4 a keep after a boundary is refused and the client still ends";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    char bb[512], kb[128];
    bb[0] = kb[0] = '\0';
    int b_ok = 0, k_ok = 0;
    size_t pre = 0, after = 0;
    int eof_pre = 0;
    long ms = -1;
    if (c.gotA) {
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        pre = _test_hold_read_window(c.fd, 60, &eof_pre);
        b_ok = _test_post_control_body(port, "/boundary", bb, sizeof(bb));
        k_ok = _test_post_control_body(port, "/seek-keep", kb, sizeof(kb));
        struct timeval tr;
        gettimeofday(&tr, NULL);
        ms = _test_connect_eof_ms(c.fd, &tr, 600, &after);
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d held_before=%zu eof_before=%d (want 0 and 0) boundary_post=%d keep_post=%d body='%.16s' (want seek_keep=0) eof_ms=%ld (want 0..300) bytes_after=%zu (want 0)",
             c.gotA, pre, eof_pre, b_ok, k_ok, kb, ms, after);
    int ok = c.gotA && pre == 0 && !eof_pre && b_ok && k_ok && strncmp(kb, "seek_keep=0", 11) == 0
          && ms >= 0 && ms <= 300 && after == 0;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C5: a keep with nothing pending changes nothing: no arm, audio flows, and a later unarmed flush still opens a window. */
static void _test_connect_c5(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C5 a keep with nothing pending is a no-op (no arm, audio flows) and a later unarmed flush still opens a window";
    const size_t lenX = 16384;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    char body[128];
    body[0] = '\0';
    int keep_ok = 0, armed0 = -1, armed1 = -1, eof_win = 0;
    size_t got = 0, win = 0;
    long first = -1, bad = -1;
    int eof = 0;
    if (c.gotA) {
        armed0 = (int)g_seek_flush_armed;
        keep_ok = _test_post_control_body(port, "/seek-keep", body, sizeof(body));
        armed1 = (int)g_seek_flush_armed;
        _test_hold_push(s, lenX, 0.5f);
        unsigned char *buf = malloc(lenX);
        got = _test_hold_collect(c.fd, 400, lenX, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.5f) : -1;
        free(buf);
        _test_connect_flush(s);
        _test_hold_push(s, lenX, 0.75f);
        win = _test_hold_read_window(c.fd, 150, &eof_win);   /* the window holds: no close, no byte */
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d keep_post=%d body='%.16s' (want seek_keep=0) armed %d->%d (want equal) got=%zu (want %zu) bad_samples=%ld first_byte_ms=%ld (want <= 200) later_flush: held=%zu eof=%d (want 0 and 0)",
             c.gotA, keep_ok, body, armed0, armed1, got, lenX, bad, first, win, eof_win);
    int ok = c.gotA && keep_ok && strncmp(body, "seek_keep=0", 11) == 0 && armed0 == armed1 && armed1 == 0
          && got == lenX && bad == 0 && first >= 0 && first <= 200 && win == 0 && !eof_win && !eof;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C6: window 0 is the contract of every older cell: an unarmed flush closes at the next tick, as before 79-50. */
static void _test_connect_c6(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C6 with window 0 an unarmed flush closes at the next tick as before 79-50";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "0", &c);
    size_t bytes = 0;
    long ms = -1;
    if (c.gotA) {
        struct timeval t0;
        gettimeofday(&t0, NULL);
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        ms = _test_connect_eof_ms(c.fd, &t0, 1500, &bytes);
    }
    /* The bytes are not asserted: with no window the post-flush push races the close and the old client may get
     * part of it (79-50 E5, C_off wrote=4096 before its close) -- exactly the pre-79-50 behaviour this cell pins. */
    char facts[256];
    snprintf(facts, sizeof(facts), "gotA=%d eof_after_flush_ms=%ld (want <= 150) bytes_before_eof=%zu (not asserted)", c.gotA, ms, bytes);
    int ok = c.gotA && ms >= 0 && ms <= 150;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C7: a keep while a write is stalled: the chunk in flight is completed, never cut, while the decision is open. */
static void _test_connect_c7(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C7 a keep while a write is stalled completes the chunk in flight and then delivers the post-flush bytes";
    const size_t lenC = 32768;
    _test_wr_reset();
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", "2000", 1);
    int fd = _test_wr_attach(port);
    int stalled = 0, keep_ok = 0;
    char body[128];
    body[0] = '\0';
    long long popped0 = 0, popped_flush = 0;
    size_t want_ramp = 0, ramp_ok = 0, tail_ok = 0;
    int got_all = 0;
    if (fd >= 0) {
        pthread_mutex_lock(&g_ring.lock);
        popped0 = (long long)g_ring.total_popped;
        pthread_mutex_unlock(&g_ring.lock);
        _test_wr_push(s, 0, _TEST_WR_SAMPLES);
        stalled = _test_wr_wait_stalled();
        pthread_mutex_lock(&g_ring.lock);
        popped_flush = (long long)g_ring.total_popped;
        pthread_mutex_unlock(&g_ring.lock);
        want_ramp = (size_t)(popped_flush - popped0);
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        keep_ok = _test_post_control_body(port, "/seek-keep", body, sizeof(body));
        unsigned char *buf = malloc(want_ramp + lenC);
        if (buf && _test_read_bytes(fd, buf, want_ramp + lenC, 8000) == 0) {
            got_all = 1;
            ramp_ok = 1;
            for (size_t i = 0; i + 3 < want_ramp; i += 4) {
                int32_t v;
                memcpy(&v, buf + i, 4);
                if (v != _test_f32_to_s32(_test_wr_ramp_f(i / 4))) {
                    ramp_ok = 0;
                    break;
                }
            }
            tail_ok = (_test_hold_bad_samples(buf + want_ramp, lenC, 0.75f) == 0);
        }
        free(buf);
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "attached=%d writer_stalled=%d popped_before_flush=%zu B keep_post=%d body='%.16s' (want seek_keep=1) read_all=%d ramp_complete_and_contiguous=%zu (want 1) post_flush_bytes_follow_directly=%zu (want 1)",
             fd >= 0, stalled, want_ramp, keep_ok, body, got_all, ramp_ok, tail_ok);
    int ok = fd >= 0 && stalled && want_ramp > 0 && keep_ok && strncmp(body, "seek_keep=1", 11) == 0
          && got_all && ramp_ok && tail_ok;
    if (fd >= 0) close(fd);
    _test_hold_verdict(failures, ok, name, facts);
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", "0", 1);
    _test_wr_reset();
}

/* C8: browse keep set: the 79-47 keep is unchanged -- no window is opened and the audio is not withheld. */
static void _test_connect_c8(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C8 with browse keep set an unarmed flush keeps the client and opens no decision window";
    const size_t lenC = 32768;
    char kb[128], trace[8192];
    kb[0] = trace[0] = '\0';
    int keep_ok = _test_browse_keep_post(port, "?on=1", kb, sizeof(kb));
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    size_t got = 0;
    long first = -1, bad = -1;
    int eof = 0;
    if (c.gotA) {
        _test_trace_t tr;
        int traced = (_test_trace_begin(&tr) == 0);
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 1500, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
        if (traced) {
            _test_trace_end(&tr, trace, sizeof(trace));
        }
    }
    int win_lit = (strstr(trace, "flush-decide: open") != NULL);
    int keep_lit = (strstr(trace, "flush-keep: browse keep set") != NULL);
    char facts[512];
    snprintf(facts, sizeof(facts), "keep_post=%d gotA=%d got=%zu (want %zu) bad_samples=%ld first_byte_ms=%ld (want <= 250) eof=%d (want 0) flush_keep_line=%d (want 1) flush_decide_open_line=%d (want 0)",
             keep_ok, c.gotA, got, lenC, bad, first, eof, keep_lit, win_lit);
    int ok = keep_ok && c.gotA && got == lenC && bad == 0 && first >= 0 && first <= 250 && !eof && keep_lit && !win_lit;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_browse_cleanup(port);
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", "0", 1);
}

/* C9 (B1): a GET /stream waiting in the pending slot survives a control newcomer: the keep is served in place. */
static void _test_connect_c9(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C9 a /seek-keep arriving while a GET /stream waits in the pending slot is served in place and the GET survives";
    const size_t lenC = 32768;
    char body[128], trace[8192];
    body[0] = trace[0] = '\0';
    _test_ring_reset();
    _test_trace_t tr;
    int traced = (_test_trace_begin(&tr) == 0);
    int g = _test_connect_loopback(port);        /* no head yet: accepted into the pending slot, idle */
    usleep(150000);
    int keep_ok = (g >= 0) ? _test_post_control_body(port, "/seek-keep", body, sizeof(body)) : 0;
    static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";
    int hdr = 0;
    size_t got = 0;
    long first = -1, bad = -1;
    int eof = 0;
    if (g >= 0 && write(g, getReq, sizeof(getReq) - 1) > 0) {
        hdr = (_test_read_header(g, 3000) == 0);
        if (hdr) {
            _test_hold_push(s, lenC, 0.75f);
            unsigned char *buf = malloc(lenC);
            got = _test_hold_collect(g, 1500, lenC, buf, &first, &eof);
            bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
            free(buf);
        }
    }
    if (traced) {
        _test_trace_end(&tr, trace, sizeof(trace));
    }
    int attach_lit = (strstr(trace, "client-attach: new /stream client") != NULL);
    char facts[512];
    snprintf(facts, sizeof(facts), "waiting_get_connected=%d keep_post=%d body='%.16s' (want seek_keep=0) get_promoted=%d client_attach_line=%d (want 1) got=%zu (want %zu) bad_samples=%ld eof=%d (want 0)",
             g >= 0, keep_ok, body, hdr, attach_lit, got, lenC, bad, eof);
    int ok = g >= 0 && keep_ok && strncmp(body, "seek_keep=0", 11) == 0 && hdr && attach_lit
          && got == lenC && bad == 0 && !eof;
    if (g >= 0) close(g);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C10 (W4): a late /seek-arm consumed by the pending disconnect ends the window: audio flows and nothing closes at the deadline. */
static void _test_connect_c10(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C10 a late seek-arm consumed by the pending disconnect ends the window and the audio flows";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    int arm_ok = 0, eof_pre = 0, eof = 0, eof2 = 0;
    size_t pre = 0, got = 0, extra = 0;
    long first = -1, bad = -1;
    int armed_after = -1;
    if (c.gotA) {
        _test_connect_flush(s);
        _test_hold_push(s, lenC, 0.75f);
        pre = _test_hold_read_window(c.fd, 120, &eof_pre);
        arm_ok = _test_post_control(port, "/seek-arm");
        armed_after = (int)g_seek_flush_armed;
        unsigned char *buf = malloc(lenC);
        got = _test_hold_collect(c.fd, 300, lenC, buf, &first, &eof);
        bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
        free(buf);
        extra = _test_hold_read_window(c.fd, 1100, &eof2);   /* past the old deadline */
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d held_before_arm=%zu eof_before_arm=%d (want 0 and 0) arm_post=%d armed_after=%d (want 0, consumed) got=%zu (want %zu) bad_samples=%ld first_byte_ms=%ld (want <= 200) extra=%zu eof=%d%d (want 00)",
             c.gotA, pre, eof_pre, arm_ok, armed_after, got, lenC, bad, first, extra, eof, eof2);
    int ok = c.gotA && pre == 0 && !eof_pre && arm_ok && armed_after == 0 && got == lenC && bad == 0
          && first >= 0 && first <= 200 && extra == 0 && !eof && !eof2;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* C11 (M1): a GET /stream taking over inside the window closes the old client and the new one is never closed by the old window. */
static void _test_connect_c11(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-C11 a takeover inside the decision window ends the window: the new client gets audio and is not closed at the deadline";
    const size_t lenC = 32768;
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    int fd2 = -1, a_eof = 0, eof = 0, eof_late = 0;
    size_t got = 0, got_late = 0;
    long first = -1, first_late = -1, bad = -1, bad_late = -1;
    struct timeval t0;
    if (c.gotA) {
        gettimeofday(&t0, NULL);
        _test_connect_flush(s);
        usleep(120000);
        fd2 = _test_hold_attach(port);
        a_eof = _test_saw_eof(c.fd, 300);
        if (fd2 >= 0) {
            _test_hold_push(s, lenC, 0.75f);
            unsigned char *buf = malloc(lenC);
            got = _test_hold_collect(fd2, 1500, lenC, buf, &first, &eof);
            bad = buf ? _test_hold_bad_samples(buf, got, 0.75f) : -1;
            free(buf);
            long wait_ms = 1500 - (long)_elapsed_ms(&t0);   /* the deadline (1000 ms) plus 500 ms */
            if (wait_ms > 0) {
                usleep((useconds_t)wait_ms * 1000);
            }
            _test_hold_push(s, lenC, 0.5f);
            buf = malloc(lenC);
            got_late = _test_hold_collect(fd2, 1500, lenC, buf, &first_late, &eof_late);
            bad_late = buf ? _test_hold_bad_samples(buf, got_late, 0.5f) : -1;
            free(buf);
        }
    }
    char facts[512];
    snprintf(facts, sizeof(facts), "gotA=%d new_attached=%d old_eof=%d (want 1) new_got=%zu (want %zu) bad=%ld first_byte_ms=%ld (want <= 200) eof=%d (want 0); after the old deadline + 500 ms: got=%zu (want %zu) bad=%ld eof=%d (want 0)",
             c.gotA, fd2 >= 0, a_eof, got, lenC, bad, first, eof, got_late, lenC, bad_late, eof_late);
    int ok = c.gotA && fd2 >= 0 && a_eof && got == lenC && bad == 0 && first >= 0 && first <= 200 && !eof
          && got_late == lenC && bad_late == 0 && !eof_late;
    if (c.fd >= 0) close(c.fd);
    if (fd2 >= 0) close(fd2);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

/* An off-loopback /seek-keep is refused (403) and changes nothing; like the hold off-loopback cell it prints `skip:` without a non-local IPv4. */
static void _test_connect_off_loopback(pa_stream *s, int port, int *failures) {
    const char *name = "connect: R2-off-loopback POST /seek-keep is refused off-loopback";
    struct ifaddrs *ifa0 = NULL, *ifa;
    struct in_addr lan;
    int haveLan = 0;
    if (getifaddrs(&ifa0) == 0) {
        for (ifa = ifa0; ifa && !haveLan; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET && (ifa->ifa_flags & IFF_UP)
                && !(ifa->ifa_flags & IFF_LOOPBACK)) {
                lan = ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr;
                haveLan = 1;
            }
        }
        freeifaddrs(ifa0);
    }
    if (!haveLan) {
        printf("skip: %s (no non-loopback IPv4 address on this host; the loopback guard is the first statement of the handler)\n", name);
        return;
    }
    _test_hc_t c;
    _test_connect_open(s, port, "1000", &c);
    char lresp[128];
    lresp[0] = '\0';
    size_t llen = 0;
    int eof_pre = 0;
    size_t pre = 0;
    if (c.gotA) {
        _test_connect_flush(s);
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in la;
        memset(&la, 0, sizeof(la));
        la.sin_family = AF_INET;
        la.sin_addr = lan;
        la.sin_port = htons((uint16_t)port);
        if (lfd >= 0 && connect(lfd, (struct sockaddr *)&la, sizeof(la)) == 0) {
            static const char lreq[] = "POST /seek-keep HTTP/1.0\r\nConnection: close\r\n\r\n";
            if (write(lfd, lreq, sizeof(lreq) - 1) > 0) {
                for (int i = 0; i < 30 && llen < sizeof(lresp) - 1; i++) {
                    struct pollfd lp;
                    lp.fd = lfd;
                    lp.events = POLLIN;
                    if (poll(&lp, 1, 100) > 0) {
                        ssize_t n = read(lfd, lresp + llen, sizeof(lresp) - 1 - llen);
                        if (n <= 0) break;
                        llen += (size_t)n;
                    }
                }
            }
        }
        lresp[llen] = '\0';
        if (lfd >= 0) close(lfd);
        pre = _test_hold_read_window(c.fd, 50, &eof_pre);   /* the window is still open: no close, no byte */
    }
    int l403 = (llen >= 12 && strncmp(lresp, "HTTP/1.0 403", 12) == 0);
    char facts[256];
    snprintf(facts, sizeof(facts), "gotA=%d answer 403=%d (%.12s) window still open: held=%zu eof=%d (want 0 and 0)",
             c.gotA, l403, lresp, pre, eof_pre);
    int ok = c.gotA && l403 && pre == 0 && !eof_pre;
    if (c.fd >= 0) close(c.fd);
    _test_hold_verdict(failures, ok, name, facts);
    _test_connect_cleanup(port);
}

static void _test_connect_cases(pa_stream *s, int port, int *failures) {
    _test_connect_c1(s, port, failures);
    _test_connect_c2(s, port, failures);
    _test_connect_c3(s, port, failures);
    _test_connect_c4(s, port, failures);
    _test_connect_c5(s, port, failures);
    _test_connect_c6(s, port, failures);
    _test_connect_c7(s, port, failures);
    _test_connect_c8(s, port, failures);
    _test_connect_c9(s, port, failures);
    _test_connect_c10(s, port, failures);
    _test_connect_c11(s, port, failures);
    _test_connect_off_loopback(s, port, failures);
}

static void _test_hold_cases(pa_stream *s, int port, int *failures) {
    _test_hold_archive(s, port, failures);
    _test_hold_timeout(s, port, failures);
    _test_hold_flush_armed(s, port, failures);
    _test_hold_flush_unarmed(s, port, failures);
    _test_hold_fresh_client(s, port, failures);
    _test_hold_steady(s, port, failures);
    _test_hold_release_active(s, port, failures);
    _test_hold_release_before_refill(s, port, failures);
    _test_hold_plain_post(s, port, failures);
    _test_hold_off_loopback(s, port, failures);
    _test_hold_gap_zero(s, port, failures);
    _test_hold_negative_clock(s, port, failures);
}

/* ==================================================================== */
/* 79-51 (runaway D2): the departed record at a bounded close, the orphan */
/* discard at promotion -- harness cells                                  */
/* ==================================================================== */
/* The album-start runaway (.planning/debug/album-start-connect-runaway.md, E4/E5):
 * a plant made with nobody attached and a ring that holds nothing of its own
 * (094204 :25.328/.338, 094408 :20.536/.550: `gen=-1 via=none ring_fill=0`) was
 * inherited by LMS's fresh stream, which was closed after 0 bytes and made LMS
 * stop. The cells below are shaped like those recordings and like a bounded EOF
 * followed by a skip flush. Every cell starts and ends with a clean ring, no
 * departed record and no marker (_test_hold_cleanup). They reach the shim only
 * through its HTTP endpoints, pa_stream_write/pa_stream_flush and the two
 * generation globals, so they compile against a shim without the fix (RED). */

#define _TEST_RW_CHUNK 16384

typedef struct {
    int       ok;
    char      via[16];
    long long gen;
    long long boundary;
    long long popped;
    char      body[512];
} _test_rw_reply_t;

/* A plain POST /boundary (the connect-mode drain anchor is not needed: the cells
 * plant at the shim's own total_pushed) and its parsed reply. */
static void _test_rw_post(int port, _test_rw_reply_t *r) {
    r->ok = _test_post_control_body(port, "/boundary", r->body, sizeof(r->body));
    _test_body_str(r->body, "via=", r->via, sizeof(r->via));
    r->gen      = _test_body_i64(r->body, "gen=");
    r->boundary = _test_body_i64(r->body, "boundary=");
    r->popped   = _test_body_i64(r->body, "total_popped=");
}

/* The generation of the client that attached last (the promotion writes it after
 * the response head left, so give the HTTP thread a moment). */
static long long _test_rw_gen_now(void) {
    usleep(60000);
    return (long long)g_client_generation;
}

/* Client A attaches, reads `len` bytes of its title, and a plain POST /boundary
 * (ring empty: the marker stands at the read pointer, via=live) gives it its
 * bounded EOF at the PRE-POP site. *gen = A's generation (the reply's gen=). */
static int _test_rw_client_ends_prepop(pa_stream *s, int port, size_t len, long long *gen) {
    *gen = -1;
    int fd = _test_hold_attach(port);
    if (fd < 0) {
        return 0;
    }
    _test_hold_push(s, len, 0.25f);
    unsigned char *sink = malloc(len);
    int got = (sink && _test_read_bytes(fd, sink, len, 3000) == 0);
    free(sink);
    int eof = 0;
    if (got) {
        _test_rw_reply_t r;
        _test_rw_post(port, &r);
        if (r.ok && strcmp(r.via, "live") == 0) {
            *gen = r.gen;
        }
        eof = _test_saw_eof(fd, 1000);
    }
    close(fd);
    return got && *gen >= 0 && eof;
}

/* Client B attaches and the harness asks the one question of the runaway: is the
 * fresh stream served, or closed in the millisecond it attached? got = bytes
 * within 500 ms, eof_early = EOF seen while collecting, eof_late = EOF in the
 * 300 ms after. */
static void _test_rw_serve(int port, size_t want, size_t *got, int *eof_early, int *eof_late, int *attached) {
    *got = 0; *eof_early = 0; *eof_late = 0;
    int fd = _test_hold_attach(port);
    *attached = (fd >= 0);
    if (fd < 0) {
        return;
    }
    long first = -1;
    *got = _test_hold_collect(fd, 500, want, NULL, &first, eof_early);
    if (!*eof_early) {
        (void)_test_hold_read_window(fd, 300, eof_late);
    }
    close(fd);
}

/* C1 (D2-a, the 094204 25.106 then 25.328 shape): a bounded EOF records its client. */
static void _test_runaway_c1(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C1 a bounded EOF records its client: the next plant (nobody attached, ring empty) reads via=departed and the fresh client is not closed at 0 bytes";
    _test_hold_cleanup(port);
    /* A: planted first with nobody attached and bytes in the ring (the D-04 shape), then attached: it reads exactly
     * its bytes and ends at the POST-POP site. */
    _test_hold_push(s, _TEST_RW_CHUNK, 0.25f);
    _test_rw_reply_t r1, r2;
    _test_rw_post(port, &r1);
    int fd = _test_hold_attach(port);
    long long gA = -1;
    size_t gotA = 0;
    int eofA = 0;
    if (fd >= 0) {
        gA = _test_rw_gen_now();
        long first = -1;
        gotA = _test_hold_collect(fd, 1500, _TEST_RW_CHUNK, NULL, &first, &eofA);
        if (!eofA) {
            eofA = _test_saw_eof(fd, 1000);
        }
        close(fd);
    }
    /* nobody attached, the ring empty: the 094204 second plant */
    _test_rw_post(port, &r2);
    _test_hold_push(s, _TEST_RW_CHUNK, 0.5f);
    size_t gotB = 0;
    int eofB1 = 0, eofB2 = 0, attB = 0;
    _test_rw_serve(port, _TEST_RW_CHUNK, &gotB, &eofB1, &eofB2, &attB);
    char facts[512];
    snprintf(facts, sizeof(facts), "first_plant via='%s' (want none) A gen=%lld got=%zu (want %d) eof=%d second_plant via='%s' (want departed) gen=%lld (want A's) B got=%zu (want >= 1) eof=%d%d (want 00)",
             r1.via, gA, gotA, _TEST_RW_CHUNK, eofA, r2.via, r2.gen, gotB, eofB1, eofB2);
    int ok = r1.ok && r2.ok && fd >= 0 && gotA == _TEST_RW_CHUNK && eofA && strcmp(r1.via, "none") == 0
          && strcmp(r2.via, "departed") == 0 && r2.gen == gA && attB && gotB >= 1 && !eofB1 && !eofB2;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C2 (D2-b, the 094408 20.536 then 20.550 shape): an orphan plant at the read pointer is discarded at the attach. */
static void _test_runaway_c2(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C2 an orphan plant at or below total_popped is discarded when the next client attaches (the fresh client is served)";
    _test_hold_cleanup(port);
    _test_trace_t tr;
    char trace[16384];
    trace[0] = '\0';
    int traced = (_test_trace_begin(&tr) == 0);
    int old_spike = g_boundary_spike;
    g_boundary_spike = 1;
    _test_rw_reply_t r;
    _test_rw_post(port, &r);
    _test_hold_push(s, _TEST_RW_CHUNK, 0.5f);
    size_t got = 0;
    int eof1 = 0, eof2 = 0, att = 0;
    _test_rw_serve(port, _TEST_RW_CHUNK, &got, &eof1, &eof2, &att);
    g_boundary_spike = old_spike;
    if (traced) {
        _test_trace_end(&tr, trace, sizeof(trace));
    }
    int discarded = strstr(trace, "boundary_discarded: orphan at attach") != NULL;
    char facts[512];
    snprintf(facts, sizeof(facts), "plant via='%s' (want none) boundary=%lld total_popped=%lld (want equal) B got=%zu (want %d) eof=%d%d (want 00) boundary_discarded_orphan=%d (want 1)",
             r.via, r.boundary, r.popped, got, _TEST_RW_CHUNK, eof1, eof2, discarded);
    int ok = traced && r.ok && strcmp(r.via, "none") == 0 && r.boundary == r.popped && att
          && got == _TEST_RW_CHUNK && !eof1 && !eof2 && discarded;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C3 (D-04 kept): a marker ABOVE total_popped with no departed record is inherited by the next client. */
static void _test_runaway_c3(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C3 a plant above total_popped with no departed record is still inherited (D-04: the next client gets exactly its bytes, then EOF)";
    _test_hold_cleanup(port);
    _test_hold_push(s, _TEST_RW_CHUNK, 0.25f);
    _test_rw_reply_t r;
    _test_rw_post(port, &r);
    int fd = _test_hold_attach(port);
    int eof = 0;
    size_t got = 0;
    if (fd >= 0) {
        got = _test_hold_read_to_eof(fd, 2000, &eof);
        close(fd);
    }
    char facts[256];
    snprintf(facts, sizeof(facts), "plant via='%s' (want none) client got=%zu (want exactly %d) eof=%d (want 1)", r.via, got, _TEST_RW_CHUNK, eof);
    int ok = r.ok && strcmp(r.via, "none") == 0 && fd >= 0 && got == _TEST_RW_CHUNK && eof;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C4 (one-shot kept): the departed record is consumed by one plant. */
static void _test_runaway_c4(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C4 the departed record is one-shot: a second plant with nobody attached reads via=none";
    _test_hold_cleanup(port);
    long long gA = -1;
    int a_ok = _test_rw_client_ends_prepop(s, port, _TEST_RW_CHUNK, &gA);
    _test_rw_reply_t r1, r2;
    _test_rw_post(port, &r1);    /* consumes the record (via=departed after 79-51) */
    _test_rw_post(port, &r2);
    char facts[256];
    snprintf(facts, sizeof(facts), "A ended=%d first plant via='%s' second plant via='%s' (want none)", a_ok, r1.via, r2.via);
    int ok = a_ok && r1.ok && r2.ok && strcmp(r2.via, "none") == 0;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C5 (attach clears): a live attach clears the record, so a plant with a client attached reads via=live. */
static void _test_runaway_c5(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C5 a live attach clears the departed record: a plant while the new client is attached reads via=live with its generation";
    _test_hold_cleanup(port);
    long long gA = -1;
    int a_ok = _test_rw_client_ends_prepop(s, port, _TEST_RW_CHUNK, &gA);
    int fd = _test_hold_attach(port);
    long long gC = (fd >= 0) ? _test_rw_gen_now() : -1;
    _test_rw_reply_t r;
    memset(&r, 0, sizeof(r));
    if (fd >= 0) {
        _test_rw_post(port, &r);
        close(fd);
    }
    char facts[256];
    snprintf(facts, sizeof(facts), "A ended=%d C gen=%lld plant via='%s' (want live) gen=%lld (want C's)", a_ok, gC, r.via, r.gen);
    int ok = a_ok && fd >= 0 && r.ok && strcmp(r.via, "live") == 0 && r.gen == gC && gC > gA;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C6 (D2-a's own case, the real skip shape: record plus flush; second review items H and I). */
static void _test_runaway_c6(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C6 after a bounded EOF and a skip flush the next plant reads via=departed and its marker is discarded at the attach (the next title is not cut at 8192 bytes)";
    const size_t lenB1 = 8192, lenRest = 16384;
    _test_hold_cleanup(port);
    _test_trace_t tr;
    char trace[16384];
    trace[0] = '\0';
    int traced = (_test_trace_begin(&tr) == 0);
    int old_spike = g_boundary_spike;
    g_boundary_spike = 1;
    long long gA = -1;
    int a_ok = _test_rw_client_ends_prepop(s, port, _TEST_RW_CHUNK, &gA);
    /* nobody attached: the intermediate title's bytes land, the skip flushes them (total_popped advances), the next
     * title's first 8192 bytes land, then the plant */
    _test_hold_push(s, _TEST_RW_CHUNK, 0.25f);
    long long popped0, popped1;
    pthread_mutex_lock(&g_ring.lock); popped0 = g_ring.total_popped; pthread_mutex_unlock(&g_ring.lock);
    pa_operation *op = pa_stream_flush(s, NULL, NULL);
    if (op) {
        pa_operation_unref(op);
    }
    pthread_mutex_lock(&g_ring.lock); popped1 = g_ring.total_popped; pthread_mutex_unlock(&g_ring.lock);
    _test_hold_push(s, lenB1, 0.5f);
    _test_rw_reply_t r;
    _test_rw_post(port, &r);
    _test_hold_push(s, lenRest, 0.5f);
    size_t got = 0;
    int eof1 = 0, eof2 = 0, att = 0;
    _test_rw_serve(port, lenB1 + lenRest, &got, &eof1, &eof2, &att);
    g_boundary_spike = old_spike;
    if (traced) {
        _test_trace_end(&tr, trace, sizeof(trace));
    }
    int stale = strstr(trace, "boundary_discarded: stale generation") != NULL;
    char facts[640];
    snprintf(facts, sizeof(facts), "A ended=%d total_popped %lld -> %lld (want advanced) plant via='%s' (want departed) boundary=%lld total_popped=%lld (want above) B got=%zu (want > %zu, all %zu) eof=%d%d (want 00) boundary_discarded_stale=%d (want 1)",
             a_ok, popped0, popped1, r.via, r.boundary, r.popped, got, lenB1, lenB1 + lenRest, eof1, eof2, stale);
    int ok = traced && a_ok && popped1 > popped0 && r.ok && strcmp(r.via, "departed") == 0 && r.boundary > r.popped
          && att && got > lenB1 && got == lenB1 + lenRest && !eof1 && !eof2 && stale;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

/* C7 (D2-a's cost, pinned): after a bounded EOF and NO flush a plant made before the next attach no longer bounds the
 * intermediate entry. HEAD bounded it (via=none, inherited). No recording shows the ordering; the cell pins the accepted
 * cost so that any later change is deliberate (T-79-192, T-79-195). */
static void _test_runaway_c7(pa_stream *s, int port, int *failures) {
    const char *name = "runaway: D2-C7 after a bounded EOF without a flush the next plant is discarded at the attach: the next client is not bounded at the marker (accepted cost, pinned)";
    const size_t lenB1 = _TEST_RW_CHUNK, lenAfter = _TEST_RW_CHUNK;
    _test_hold_cleanup(port);
    long long gA = -1;
    int a_ok = _test_rw_client_ends_prepop(s, port, _TEST_RW_CHUNK, &gA);
    _test_hold_push(s, lenB1, 0.25f);    /* the intermediate title, no flush */
    _test_rw_reply_t r;
    _test_rw_post(port, &r);
    _test_hold_push(s, lenAfter, 0.5f);  /* bytes after the marker */
    size_t got = 0;
    int eof1 = 0, eof2 = 0, att = 0;
    _test_rw_serve(port, lenB1 + lenAfter, &got, &eof1, &eof2, &att);
    char facts[512];
    snprintf(facts, sizeof(facts), "A ended=%d plant via='%s' (want departed) boundary=%lld total_popped=%lld (want above) B got=%zu (want %zu: B1 and the bytes after the marker) eof=%d%d (want 00; HEAD bounded B at %zu)",
             a_ok, r.via, r.boundary, r.popped, got, lenB1 + lenAfter, eof1, eof2, lenB1);
    int ok = a_ok && r.ok && strcmp(r.via, "departed") == 0 && r.boundary > r.popped && att
          && got == lenB1 + lenAfter && !eof1 && !eof2;
    _test_hold_verdict(failures, ok, name, facts);
    _test_hold_cleanup(port);
}

static void _test_runaway_cases(pa_stream *s, int port, int *failures) {
    _test_runaway_c1(s, port, failures);
    _test_runaway_c2(s, port, failures);
    _test_runaway_c3(s, port, failures);
    _test_runaway_c4(s, port, failures);
    _test_runaway_c5(s, port, failures);
    _test_runaway_c6(s, port, failures);
    _test_runaway_c7(s, port, failures);
}

int main(void) {
    int failures = 0;
    const int hold_only = (getenv("FAKE_LIBPULSE_TEST_HOLD_ONLY") != NULL);
    /* 79-47 (D-34): the browse-keep cells alone, used by t/soloist/48 for the
     * browse-keep mutant (the old unarmed flush-disconnect). */
    const int browse_only = (getenv("FAKE_LIBPULSE_TEST_BROWSE_ONLY") != NULL);
    /* 79-50 (D-34 R2): the connect decision-window cells alone, used by t/soloist/48
     * for the window mutants (the R2_DEFER / R2_PROMOTE / R2_TAKEOVER blocks). */
    const int connect_only = (getenv("FAKE_LIBPULSE_TEST_CONNECT_ONLY") != NULL);
    /* 79-51 (runaway D2): the departed-record / orphan-discard cells alone, used by t/soloist/48
     * for the D2 mutants (the 79-51 D2_DEPART and D2_ORPHAN blocks). */
    const int runaway_only = (getenv("FAKE_LIBPULSE_TEST_RUNAWAY_ONLY") != NULL);

    /* 84-20: stdout and stderr go to one pipe under prove; a block-buffered
     * stdout let a FAIL line land inside a half-written `ok:` line, which the
     * t/48 line match then missed. Line-buffered, every line stays whole. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* 84-20: every older case keeps the 84-17 contract; each vsink case sets
     * its own T and restores 0. */
    setenv("SPOTON_FAKEPULSE_VSINK_MS", "0", 1);
    /* 79-37 D-31: the gap hold is off for every older cell; each hold cell
     * sets its own knobs and restores 0. */
    setenv("SPOTON_FAKEPULSE_HOLD_GAP_MS", "0", 1);
    /* 79-50 D-34 R2: the connect decision window is off for every older cell (an
     * unarmed flush closes at the next tick, the contract they were written
     * under); each connect cell sets its own window and restores 0. */
    setenv("SPOTON_FAKEPULSE_FLUSH_DECIDE_MS", "0", 1);

    /* quick-261022-ca3: the read helpers must measure a sub-second budget in
     * elapsed milliseconds across a wall-clock second boundary. */
    if (!hold_only && !browse_only && !connect_only && !runaway_only) {
        long ms_b = 0, ms_h = 0, ms_r = 0;
        int rc_b = _test_boundary_probe(0, &ms_b);
        int rc_h = _test_boundary_probe(1, &ms_h);
        int rc_r = _test_boundary_probe(2, &ms_r);
        if (rc_b == -9 || rc_h == -9 || rc_r == -9) {
            fprintf(stderr, "FAIL: test helpers: second-boundary probe could not be armed in 10 attempts\n");
            failures++;
        } else if (rc_b != 0 || rc_h != 0 || rc_r != 0) {
            fprintf(stderr, "FAIL: test helpers: a sub-second read budget is measured in elapsed milliseconds across a wall-clock second boundary (read_bytes rc=%d %ld ms, read_header rc=%d %ld ms, read_response rc=%d %ld ms, budget 500 ms)\n",
                    rc_b, ms_b, rc_h, ms_h, rc_r, ms_r);
            failures++;
        } else {
            printf("ok: test helpers: a sub-second read budget is measured in elapsed milliseconds across a wall-clock second boundary (read_bytes %ld ms, read_header %ld ms, read_response %ld ms, budget 500 ms)\n",
                   ms_b, ms_h, ms_r);
        }
    }

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

    /* 79-37 D-31: the gap-hold cells run first, in both modes, so the
     * hold-only mode (FAKE_LIBPULSE_TEST_HOLD_ONLY, used by t/soloist/48 for
     * the hold-cap mutant) executes exactly the code path and order of the
     * full run. */
    if (runaway_only) {
        _test_runaway_cases(s, port, &failures);
        printf("Runaway-only run: failures=%d\n", failures);
        unlink(portFilePath);
        return failures > 0 ? 1 : 0;
    }
    if (connect_only) {
        _test_connect_cases(s, port, &failures);
        printf("Connect-only run: failures=%d\n", failures);
        unlink(portFilePath);
        return failures > 0 ? 1 : 0;
    }
    if (browse_only) {
        _test_browse_cases(s, port, &failures);
        printf("Browse-only run: failures=%d\n", failures);
        unlink(portFilePath);
        return failures > 0 ? 1 : 0;
    }
    _test_hold_cases(s, port, &failures);
    if (hold_only) {
        printf("Hold-only run: failures=%d\n", failures);
        unlink(portFilePath);
        return failures > 0 ? 1 : 0;
    }
    /* 79-47 (D-34): the browse-keep cells, right after the hold cells. */
    _test_browse_cases(s, port, &failures);
    /* 79-50 (D-34 R2): the connect decision-window cells, right after the browse cells. */
    _test_connect_cases(s, port, &failures);
    /* 79-51 (runaway D2): the departed-record / orphan-discard cells, right after the connect cells. */
    _test_runaway_cases(s, port, &failures);

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

        /* debug connect-seek-stoppt-wiedergabe (2026-09-24): the detach
         * above only clears g_ring.client_connected, which no product
         * code reads -- the drain loop keys on its own client_fd, so it
         * could still serve the pattern below before the flush (observed:
         * "flushed bytes leaked?"), and this test's UNARMED flush raises
         * g_flush_disconnect (D-12, added after 73-06), so the loop top
         * could close `client` before the fresh pattern reached it
         * (observed: "did not receive post-flush pattern"; 3/10 baseline
         * runs failed one of the two). Arming the flush first makes both
         * deterministic without changing what is asserted: the drain gate
         * withholds the to-be-flushed pattern, and the armed flush
         * discards it while keeping `client`. The unarmed disconnect is
         * covered by the reconnect-after-flush-disconnect and queued
         * seek-arm negative-control tests. */
        if (!_test_post_control(port, "/seek-arm")) {
            fprintf(stderr, "FAIL: flush test: POST /seek-arm did not return 200 OK\n");
            failures++;
        }

        /* Second, recognizable pattern -- must be discarded by the
         * flush below and never reach the client. */
        float flushed_pattern[4] = { 0.25f, -0.25f, 0.75f, -0.75f };
        pa_stream_write(s, flushed_pattern, sizeof(flushed_pattern), NULL, 0, 0);

        size_t after_write = pa_stream_writable_size(s);

        if (before != (size_t)RING_CAPACITY - _TEST_WRITE_MARGIN) {
            fprintf(stderr, "FAIL: writable_size before flush-test write != capacity - write margin (before=%zu)\n", before);
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

        if (after_flush != (size_t)RING_CAPACITY - _TEST_WRITE_MARGIN) {
            fprintf(stderr, "FAIL: writable_size not back to full capacity - write margin after flush (after_flush=%zu, capacity=%d)\n",
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
     * fresh audio within 500ms of its GET.
     * quick-261022-ca3: the 500 ms bound is measured from the fresh write
     * to the first audio byte (not from the connect), and each failure
     * reason (closed, nothing delivered, delivered late) has its own text. */
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
                    struct timeval wt0;
                    gettimeofday(&wt0, NULL);

                    /* quick-261022-ca3: the 500 ms bound is the latency from
                     * the write to the first audio byte on the reconnected
                     * client (ten 50 ms drain ticks; the historical defect
                     * this pins was a ~8 s gap). Delivery is waited for up to
                     * 3000 ms, the same wait as the other reads in this
                     * harness, so a slow runner never turns a late-but-present
                     * delivery into "no audio"; lateness is judged against
                     * the bound afterwards, with its own reason text. */
                    const long reconnect_bound_ms = 500;
                    unsigned char got[8];
                    int rrc = _test_read_bytes(new_fd, got, sizeof(got), 3000);
                    long lat = _elapsed_ms(&wt0);

                    if (rrc == -2) {
                        fprintf(stderr, "FAIL: reconnected client received no audio within 500ms (connection closed after %ld ms)\n", lat);
                        failures++;
                    } else if (rrc != 0) {
                        fprintf(stderr, "FAIL: reconnected client received no audio within 500ms (none within the 3000 ms delivery wait)\n");
                        failures++;
                    } else if (lat > reconnect_bound_ms) {
                        fprintf(stderr, "FAIL: reconnected client received no audio within 500ms (first audio after %ld ms)\n", lat);
                        failures++;
                    } else if (memcmp(got, expected_reconnect, sizeof(expected_reconnect)) != 0) {
                        fprintf(stderr, "FAIL: reconnected client received stale/wrong bytes\n");
                        failures++;
                    } else {
                        printf("ok: reconnect after flush-disconnect attaches and drains immediately (first audio %ld ms after the write, bound 500 ms)\n", lat);
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
                    struct timeval cs;
                    gettimeofday(&cs, NULL);
                    while (rlen < sizeof(resp) - 1) {
                        struct pollfd pfd; pfd.fd = ctrl; pfd.events = POLLIN;
                        if (poll(&pfd, 1, 200) > 0) {
                            ssize_t n = read(ctrl, resp + rlen, sizeof(resp) - 1 - rlen);
                            if (n <= 0) break;
                            rlen += (size_t)n;
                        }
                        if (_elapsed_ms(&cs) >= 2000) break;
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
             * 84-17 (plan-checker W2): the serve loop now pops only up to
             * the marker, so this chunk stays in the ring for the NEXT
             * client (it used to be popped-and-discarded by the drain
             * cycle that closed bfd -- the prototype limitation of the
             * old write_n comment). Verified as "0 bytes leak to bfd"
             * below AND as "arrives intact for the fresh client". */
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
             * one-shot marker must not linger past its own consumption.
             * 84-17: it now receives afterMarker FIRST (the bytes the old
             * pop-then-trim dropped), then the later write. */
            float postClose[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
            int32_t expected_afterAndPost[8] = { 2147483647, -2147483647, 0, 0,
                                                 268435456, -268435456, 0, 2147483647 };
            pa_stream_write(s, postClose, sizeof(postClose), NULL, 0, 0);

            int nfd = _test_connect_loopback(port);
            if (nfd < 0) {
                fprintf(stderr, "FAIL: could not open fresh client after boundary EOF\n");
                failures++;
            } else {
                unsigned char got_post[32];
                if (write(nfd, getReq, sizeof(getReq) - 1) < 0
                    || _test_read_header(nfd, 3000) != 0
                    || _test_read_bytes(nfd, got_post, sizeof(got_post), 3000) != 0) {
                    fprintf(stderr, "FAIL: fresh client after boundary EOF did not stream normally\n");
                    failures++;
                } else if (memcmp(got_post, expected_afterAndPost, sizeof(expected_afterAndPost)) != 0) {
                    fprintf(stderr, "FAIL: fresh client after boundary EOF received wrong bytes (84-17: afterMarker first, then postClose)\n");
                    failures++;
                } else {
                    printf("ok: fresh client after boundary EOF streams normally again\n");
                }
                close(nfd);
            }
        }
    }

    /* ------------------------------------------------------------------
     * 84-17 (L1 repair, plan 84-17 Task 1): the shim tells SpotOn what a
     * title change was. POST /boundary answers with a text body
     * `via=<live|departed|none> boundary=<pos> anchor=<drain|popped|pushed>
     * ring_fill=.. total_pushed=.. total_popped=.. drops=.. gen=..` and a
     * correct Content-Length; a connect-mode post (`?anchor=drain`) plants
     * a live boundary at the drained end of the old title; the ring counts
     * dropped bytes; the serve loop pops only up to the marker. Every check
     * below was shown RED on the unchanged C (reply body empty, no anchor
     * query, no counter, pop-then-trim) before the change.
     * ------------------------------------------------------------------ */

    /* via=live (a streaming client attached at POST time, plain path:
     * today's placement at total_pushed), then via=none right after the
     * bounded EOF left nobody attached (the rapid-skip situation).
     * Corrected 79-51 (2026-10-27): after a bounded EOF the next plant now reads
     * via=departed (cell runaway: D2-C1); the via=none read below is made with the
     * departed record cleared first. The rapid-skip bound after a bounded EOF is
     * kept only after a flush (C6); without a flush it is given up (C7, T-79-195). */
    {
        _test_brun_t run;
        _test_boundary_run(s, port, "/boundary", 44100 * 2 * 1, 44100 * 2 / 2, &run);
        char via[16], anchor[16];
        _test_body_str(run.body, "via=", via, sizeof(via));
        _test_body_str(run.body, "anchor=", anchor, sizeof(anchor));
        long long boundary = _test_body_i64(run.body, "boundary=");
        long long tpush    = _test_body_i64(run.body, "total_pushed=");
        long long drops    = _test_body_i64(run.body, "drops=");
        long long gen      = _test_body_i64(run.body, "gen=");
        if (!run.attached || !run.post_ok || !run.eof || strcmp(via, "live") != 0
            || boundary < 0 || strcmp(anchor, "pushed") != 0 || drops != 0 || gen < 0) {
            fprintf(stderr, "FAIL: boundary reply body carries via=live: attached=%d post_ok(200+Content-Length==body)=%d eof=%d via='%s' boundary=%lld anchor='%s' drops=%lld gen=%lld body='%.120s'\n",
                    run.attached, run.post_ok, run.eof, via, boundary, anchor, drops, gen, run.body);
            failures++;
        } else {
            printf("ok: boundary reply body carries via=live (anchor=pushed boundary=%lld drops=0, Content-Length == body)\n", boundary);
        }

        if (!run.post_ok || boundary < 0 || boundary != tpush || boundary != run.pushed_end
            || (int64_t)run.received != boundary - run.base) {
            fprintf(stderr, "FAIL: live boundary without the anchor query is planted at total_pushed: boundary=%lld total_pushed(reply)=%lld pushed_end=%lld received=%zu base=%lld\n",
                    boundary, tpush, (long long)run.pushed_end, run.received, (long long)run.base);
            failures++;
        } else {
            printf("ok: live boundary without the anchor query is planted at total_pushed (boundary=%lld, client received exactly up to it)\n", boundary);
        }

        /* The bounded EOF left nobody attached and no departed record.
         * Corrected 79-51 (2026-10-27): after 79-51 runaway D2 a bounded EOF DOES leave a departed record, and the next
         * plant reads via=departed (cell runaway: D2-C1). This cell's own claim -- no client ever attached to this
         * plant -- is kept by clearing the record before the POST. The rapid-skip bound after a bounded EOF is kept
         * only after a flush (C6 shows why discarding is right there); without a flush it is given up (C7, T-79-195). */
        char none_body[512];
        g_departed_client_generation = NO_CLIENT_GENERATION;
        g_boundary_at_pushed = -1;
        int none_ok = _test_post_control_body(port, "/boundary", none_body, sizeof(none_body));
        char via2[16], anchor2[16];
        _test_body_str(none_body, "via=", via2, sizeof(via2));
        _test_body_str(none_body, "anchor=", anchor2, sizeof(anchor2));
        if (!none_ok || strcmp(via2, "none") != 0 || strcmp(anchor2, "pushed") != 0) {
            fprintf(stderr, "FAIL: boundary reply body carries via=none: post_ok=%d via='%s' anchor='%s' body='%.120s'\n",
                    none_ok, via2, anchor2, none_body);
            failures++;
        } else {
            printf("ok: boundary reply body carries via=none (no client ever attached to this plant, anchor=pushed)\n");
        }
        g_boundary_at_pushed = -1;
    }

    /* 84-17 (found live in the skip regression: `attrib skip app` read
     * CHANGE_VIA=live and SKIP_DELAY_S=16.5): since the stall fix the HTTP
     * thread serves a control POST INSIDE a stalled client write (LMS's proxy
     * socket is full while the player's buffers hold the tail). The daemon's
     * skip flush has raised g_flush_disconnect by then, but the disconnect
     * only executes at the loop top -- the client is still attached when the
     * POST is served, so the reply said `live` (a natural end) and Connect
     * HELD the new title behind the old one: the skip took effect only after
     * the old title's tail. A pending unarmed flush-disconnect IS the skip:
     * the reply must say `departed` (and place no drain anchor) the moment the
     * flush has happened. Shape: a client that reads nothing (the thread stalls
     * in its write), the skip's unarmed flush, at once POST /boundary?anchor=drain. */
    {
        _test_ring_reset();
        g_departed_client_generation = NO_CLIENT_GENERATION;
        int stall2 = socket(AF_INET, SOCK_STREAM, 0);
        int rcv2 = 2048;
        setsockopt(stall2, SOL_SOCKET, SO_RCVBUF, &rcv2, sizeof(rcv2));
        struct sockaddr_in sa2;
        memset(&sa2, 0, sizeof(sa2));
        sa2.sin_family = AF_INET;
        sa2.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa2.sin_port = htons((uint16_t)port);
        static const char getReqP[] = "GET /stream HTTP/1.0\r\n\r\n";
        int p_att = (stall2 >= 0 && connect(stall2, (struct sockaddr *)&sa2, sizeof(sa2)) == 0
                     && write(stall2, getReqP, sizeof(getReqP) - 1) > 0 && _test_read_header(stall2, 3000) == 0);
        int p_ok = 0;
        char pbody[512];
        pbody[0] = '\0';
        if (p_att) {
            size_t step = 131072;
            float *blk = malloc(step * sizeof(float));
            if (blk) {
                for (size_t i = 0; i < step; i++) blk[i] = 0.25f;
                setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "100", 1);
                for (int i = 0; i < 24; i++) {   /* 12 MB: past what the socket buffers take */
                    pa_stream_write(s, blk, step * sizeof(float), NULL, 0, 0);
                    usleep(50000);
                }
                unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
                free(blk);
            }
            usleep(300000);   /* the HTTP thread is now stalled in its client write */
            pa_operation *pop = pa_stream_flush(s, NULL, NULL);   /* the skip: unarmed -> g_flush_disconnect */
            if (pop) pa_operation_unref(pop);
            p_ok = _test_post_control_body(port, "/boundary?anchor=drain", pbody, sizeof(pbody));
        }
        char pvia[16], panchor[16];
        _test_body_str(pbody, "via=", pvia, sizeof(pvia));
        _test_body_str(pbody, "anchor=", panchor, sizeof(panchor));
        if (!p_att || !p_ok || strcmp(pvia, "departed") != 0 || strcmp(panchor, "drain") == 0) {
            fprintf(stderr, "FAIL: a skip's pending flush-disconnect is answered via=departed at once: attached=%d ok=%d via='%s' anchor='%s' body='%.120s'\n",
                    p_att, p_ok, pvia, panchor, pbody);
            failures++;
        } else {
            printf("ok: a skip's pending flush-disconnect is answered via=departed at once (anchor=%s, served inside the stalled client write)\n", panchor);
        }
        if (stall2 >= 0) close(stall2);
        usleep(200000);
        _test_ring_reset();
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;
        g_flush_disconnect = 0;
        g_departed_client_generation = NO_CLIENT_GENERATION;
    }

    /* via=departed: an unarmed flush-disconnect closed the old client, the
     * old title's /boundary arrives afterwards (the situation of the
     * departed-client check further below). */
    {
        _test_ring_reset();
        g_departed_client_generation = NO_CLIENT_GENERATION;
        static const char getReqD[] = "GET /stream HTTP/1.0\r\n\r\n";
        int dfd = _test_connect_loopback(port);
        int d_ok = 0;
        char dbody[512];
        dbody[0] = '\0';
        if (dfd >= 0 && write(dfd, getReqD, sizeof(getReqD) - 1) >= 0 && _test_read_header(dfd, 3000) == 0) {
            float oldD[2] = { 0.5f, -0.5f };
            pa_stream_write(s, oldD, sizeof(oldD), NULL, 0, 0);
            unsigned char gotOldD[8];
            int draining = (_test_read_bytes(dfd, gotOldD, sizeof(gotOldD), 3000) == 0);
            pa_operation *dop = pa_stream_flush(s, NULL, NULL);
            if (dop) pa_operation_unref(dop);
            int closed = draining && _test_saw_eof(dfd, 1000);
            d_ok = closed && _test_post_control_body(port, "/boundary", dbody, sizeof(dbody));
        }
        if (dfd >= 0) close(dfd);
        char dvia[16], danchor[16];
        _test_body_str(dbody, "via=", dvia, sizeof(dvia));
        _test_body_str(dbody, "anchor=", danchor, sizeof(danchor));
        if (!d_ok || strcmp(dvia, "departed") != 0) {
            fprintf(stderr, "FAIL: boundary reply body carries via=departed: ok=%d via='%s' body='%.120s'\n",
                    d_ok, dvia, dbody);
            failures++;
        } else {
            printf("ok: boundary reply body carries via=departed (the unarmed flush-disconnect's client; anchor=%s)\n", danchor);
        }
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;
        g_departed_client_generation = NO_CLIENT_GENERATION;
    }

    /* The drained end of the old title: a live client reads everything
     * (ring empty), 1 s of the next title lands (empty -> filled), the
     * connect-mode post `?anchor=drain` plants at that empty-to-filled
     * position -- or, when the live client had already read into the new
     * title, at what it had read (anchor=popped; the 84-17 floor) -- and
     * never at total_pushed, so nothing of the new title beyond what was
     * already read reaches the old stream. */
    {
        _test_brun_t run;
        size_t floatsA = 44100 * 2 * 2;   /* 2 s */
        _test_boundary_run(s, port, "/boundary?anchor=drain", floatsA, 44100 * 2 * 1, &run);
        char via[16], anchor[16];
        _test_body_str(run.body, "via=", via, sizeof(via));
        _test_body_str(run.body, "anchor=", anchor, sizeof(anchor));
        long long boundary = _test_body_i64(run.body, "boundary=");
        long long tpush    = _test_body_i64(run.body, "total_pushed=");
        long long tpop     = _test_body_i64(run.body, "total_popped=");
        long long drain_pos = (long long)run.base + (long long)(floatsA * sizeof(float));
        int anchor_ok = (strcmp(anchor, "drain") == 0 && boundary == drain_pos)
                     || (strcmp(anchor, "popped") == 0 && boundary == tpop && boundary >= drain_pos);
        if (!run.attached || !run.post_ok || !run.eof || strcmp(via, "live") != 0 || !anchor_ok
            || boundary >= tpush
            || (long long)run.received != boundary - (long long)run.base
            || (long long)run.fill_after != (long long)run.pushed_end - boundary) {
            fprintf(stderr, "FAIL: live boundary anchored at the drain point: attached=%d post_ok=%d eof=%d via='%s' anchor='%s' boundary=%lld drain_pos=%lld total_popped=%lld total_pushed=%lld received=%zu (want %lld) fill_after=%zu (want %lld)\n",
                    run.attached, run.post_ok, run.eof, via, anchor, boundary, drain_pos, tpop, tpush,
                    run.received, boundary - (long long)run.base, run.fill_after,
                    (long long)run.pushed_end - boundary);
            failures++;
        } else {
            printf("ok: live boundary anchored at the drain point (anchor=%s boundary=%lld, old stream got exactly up to it, %zu bytes of the new title stayed in the ring)\n",
                   anchor, boundary, run.fill_after);
        }
        g_boundary_at_pushed = -1;
    }

    /* Drop counter: no client, push capacity + 1 s -> the overflow is
     * refused at the (shortened) write ceiling and COUNTED (reply `drops=`),
     * and write_summary reports the same number. 84-17: a full ring no
     * longer discards the oldest audio; what finds no room within the
     * ceiling is refused and counted, nothing is silent. */
    {
        setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "200", 1);
        _test_ring_reset();
        char b0[512], b1[512];
        int ok0 = _test_post_control_body(port, "/boundary", b0, sizeof(b0));
        g_boundary_at_pushed = -1;
        long long d0 = _test_body_i64(b0, "drops=");

        size_t extra = RING_BYTES_PER_SEC;   /* 1 s of overflow */
        size_t nfloats = (RING_CAPACITY + extra) / sizeof(float);
        float *big = malloc(nfloats * sizeof(float));
        long long d1 = -1;
        int ok1 = 0;
        if (big) {
            for (size_t i = 0; i < nfloats; i++) big[i] = 0.25f;
            pa_stream_write(s, big, nfloats * sizeof(float), NULL, 0, 0);
            free(big);
            ok1 = _test_post_control_body(port, "/boundary", b1, sizeof(b1));
            g_boundary_at_pushed = -1;
            d1 = _test_body_i64(b1, "drops=");
        }

        /* write_summary: one forced summary line, stderr captured. */
        long long dsum = -1;
        _test_ring_reset();
        char tmpl[] = "/tmp/fake-libpulse-test-ws-XXXXXX";
        int tfd = mkstemp(tmpl);
        if (tfd >= 0) {
            fflush(stderr);
            int saved = dup(2);
            dup2(tfd, 2);
            g_boundary_spike = 1;
            g_boundary_write_summary_set = 0;
            float one[2] = { 0.1f, 0.1f };
            pa_stream_write(s, one, sizeof(one), NULL, 0, 0);
            fflush(stderr);
            g_boundary_spike = 0;
            dup2(saved, 2);
            close(saved);
            char logbuf[8192];
            ssize_t ln = pread(tfd, logbuf, sizeof(logbuf) - 1, 0);
            logbuf[ln > 0 ? ln : 0] = '\0';
            char *line = strstr(logbuf, "write_summary:");
            const char *dv = line ? strstr(line, "drops=") : NULL;
            if (dv) dsum = strtoll(dv + 6, NULL, 10);
            close(tfd);
            unlink(tmpl);
        }

        if (!ok0 || !ok1 || d0 < 0 || d1 != d0 + (long long)extra || dsum != d1) {
            fprintf(stderr, "FAIL: ring drop counter counts dropped bytes: ok0=%d ok1=%d drops_before=%lld drops_after=%lld (want %lld) write_summary_drops=%lld\n",
                    ok0, ok1, d0, d1, d0 + (long long)extra, dsum);
            failures++;
        } else {
            printf("ok: ring drop counter counts dropped bytes (drops %lld -> %lld = +%zu, write_summary reports the same)\n", d0, d1, extra);
        }
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        _test_ring_reset();
    }

    /* Pop only up to the marker (plan-checker W2): the old pop-then-trim
     * took a whole 16 KB chunk out of the ring and cut it at the marker,
     * so up to 16383 bytes of the NEXT title were lost at every boundary.
     * Plant at |A|, push B, the old client reads exactly |A|; the next
     * client must start at B's first byte. */
    {
        _test_ring_reset();
        static const char getReqP[] = "GET /stream HTTP/1.0\r\n\r\n";
        int pfd1 = _test_connect_loopback(port);
        int p_ok = (pfd1 >= 0 && write(pfd1, getReqP, sizeof(getReqP) - 1) >= 0
                    && _test_read_header(pfd1, 3000) == 0);
        size_t received = 0;
        int got_eof = 0;
        int second_ok = 0;
        size_t floatsA = 44100 * 2 * 1;
        size_t floatsB = 44100 * 2 * 1;
        if (p_ok) {
            float *a = malloc(floatsA * sizeof(float));
            float *b = malloc(floatsB * sizeof(float));
            if (a && b) {
                for (size_t i = 0; i < floatsA; i++) a[i] = 0.25f;
                for (size_t i = 0; i < floatsB; i++) b[i] = 0.001f * (float)((i % 900) + 1);
                pa_stream_write(s, a, floatsA * sizeof(float), NULL, 0, 0);
                char pbody[512];
                int plant_ok = _test_post_control_body(port, "/boundary", pbody, sizeof(pbody));
                pa_stream_write(s, b, floatsB * sizeof(float), NULL, 0, 0);
                unsigned char buf[65536];
                for (int i = 0; i < 400 && !got_eof; i++) {
                    struct pollfd pfd; pfd.fd = pfd1; pfd.events = POLLIN;
                    if (poll(&pfd, 1, 10) > 0) {
                        ssize_t n = read(pfd1, buf, sizeof(buf));
                        if (n == 0) got_eof = 1;
                        else if (n < 0 && errno != EAGAIN && errno != EINTR) got_eof = 1;
                        else if (n > 0) received += (size_t)n;
                    }
                }
                if (plant_ok && got_eof) {
                    int pfd2 = _test_connect_loopback(port);
                    unsigned char gotB[64];
                    if (pfd2 >= 0 && write(pfd2, getReqP, sizeof(getReqP) - 1) >= 0
                        && _test_read_header(pfd2, 3000) == 0
                        && _test_read_bytes(pfd2, gotB, sizeof(gotB), 3000) == 0) {
                        int32_t want[16];
                        for (int i = 0; i < 16; i++) want[i] = _test_f32_to_s32(b[i]);
                        second_ok = (memcmp(gotB, want, sizeof(want)) == 0);
                    }
                    if (pfd2 >= 0) close(pfd2);
                }
            }
            free(a);
            free(b);
        }
        if (pfd1 >= 0) close(pfd1);
        if (!p_ok || !got_eof || received != floatsA * sizeof(float) || !second_ok) {
            fprintf(stderr, "FAIL: bounded EOF pops nothing past the marker: attached=%d eof=%d old client received %zu (want %zu) next client starts at B's first byte=%d\n",
                    p_ok, got_eof, received, floatsA * sizeof(float), second_ok);
            failures++;
        } else {
            printf("ok: bounded EOF pops nothing past the marker (old client got exactly %zu bytes, the next client starts at the first byte of the next title)\n", received);
        }
        g_boundary_at_pushed = -1;
    }

    /* A marker exactly at the read pointer (everything before it already
     * popped) closes the client at the next tick WITHOUT a pop -- the old
     * loop needed another byte in the ring to ever notice the marker. */
    {
        _test_ring_reset();
        static const char getReqQ[] = "GET /stream HTTP/1.0\r\n\r\n";
        int qfd = _test_connect_loopback(port);
        int q_attached = (qfd >= 0 && write(qfd, getReqQ, sizeof(getReqQ) - 1) >= 0
                          && _test_read_header(qfd, 3000) == 0);
        int q_eof = 0;
        int q_next_ok = 0;
        if (q_attached) {
            float preQ[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
            pa_stream_write(s, preQ, sizeof(preQ), NULL, 0, 0);
            unsigned char gotQ[16];
            int q_read = (_test_read_bytes(qfd, gotQ, sizeof(gotQ), 3000) == 0);
            int q_post = q_read && _test_post_control(port, "/boundary");
            /* nothing further is written: the EOF must still come */
            q_eof = q_post && _test_saw_eof(qfd, 500);
            if (q_eof) {
                float nextQ[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
                int32_t want[4] = { 2147483647, -2147483647, 0, 0 };
                pa_stream_write(s, nextQ, sizeof(nextQ), NULL, 0, 0);
                int nfd2 = _test_connect_loopback(port);
                unsigned char gotN[16];
                if (nfd2 >= 0 && write(nfd2, getReqQ, sizeof(getReqQ) - 1) >= 0
                    && _test_read_header(nfd2, 3000) == 0
                    && _test_read_bytes(nfd2, gotN, sizeof(gotN), 3000) == 0) {
                    q_next_ok = (memcmp(gotN, want, sizeof(want)) == 0);
                }
                if (nfd2 >= 0) close(nfd2);
            }
        }
        if (qfd >= 0) close(qfd);
        if (!q_attached || !q_eof || !q_next_ok) {
            fprintf(stderr, "FAIL: bounded EOF exactly at the marker closes without a pop: attached=%d eof_within_500ms=%d next_client_gets_next_write_first=%d\n",
                    q_attached, q_eof, q_next_ok);
            failures++;
        } else {
            printf("ok: bounded EOF exactly at the marker closes without a pop (EOF with nothing further written; the next client starts at the next write)\n");
        }
        g_boundary_at_pushed = -1;
    }

    /* 84-17 (found live in the long-tail proof, 2026-10-01 11:21:19): the HTTP
     * thread serves the control endpoints AND writes to the streaming client.
     * _http_write_all waited up to 2 s for POLLOUT, so whenever the client did
     * not read (LMS, whose player buffers hold a long tail, stops reading the
     * proxy socket) a POST /boundary sent right then waited for the stalled
     * write -- 304 ms in the live run, past Control's 0.3 s reply cap (the
     * change then took the immediate path and cut the 32 s tail) -- and was
     * finally answered `departed`, because the stalled client had closed
     * meanwhile. The control endpoints must be served WHILE a client write is
     * stalled: a client that reads nothing (tiny receive buffer), a ring
     * pushed far beyond what the socket takes, then POST /boundary must be
     * answered promptly with via=live. */
    {
        _test_ring_reset();
        int stall_fd = socket(AF_INET, SOCK_STREAM, 0);
        int rcv = 2048;
        setsockopt(stall_fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa.sin_port = htons((uint16_t)port);
        int s_ok = (stall_fd >= 0 && connect(stall_fd, (struct sockaddr *)&sa, sizeof(sa)) == 0);
        static const char getReqW[] = "GET /stream HTTP/1.0\r\n\r\n";
        s_ok = s_ok && write(stall_fd, getReqW, sizeof(getReqW) - 1) > 0 && _test_read_header(stall_fd, 3000) == 0;
        char wbody[512];
        wbody[0] = '\0';
        int w_post_ok = 0;
        long w_ms = -1;
        size_t w_fill = 0;
        if (s_ok) {
            /* 12 MB in 0.5 MB steps; the client never reads, so the socket fills and the thread stalls in its write */
            size_t step = 131072;   /* floats = 0.5 MB of S32 */
            float *blk = malloc(step * sizeof(float));
            if (blk) {
                for (size_t i = 0; i < step; i++) blk[i] = 0.25f;
                /* 84-17: a full ring makes the writer WAIT (not discard); a short
                 * ceiling keeps this one test writer from waiting its default 120 s. */
                setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "100", 1);
                for (int i = 0; i < 24; i++) {
                    pa_stream_write(s, blk, step * sizeof(float), NULL, 0, 0);
                    usleep(50000);
                }
                unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
                free(blk);
            }
            usleep(300000);
            pthread_mutex_lock(&g_ring.lock);
            w_fill = g_ring.fill;
            pthread_mutex_unlock(&g_ring.lock);
            struct timeval wt0, wt1;
            gettimeofday(&wt0, NULL);
            w_post_ok = _test_post_control_body(port, "/boundary?anchor=drain", wbody, sizeof(wbody));
            gettimeofday(&wt1, NULL);
            w_ms = (wt1.tv_sec - wt0.tv_sec) * 1000 + (wt1.tv_usec - wt0.tv_usec) / 1000;
        }
        char wvia[16];
        _test_body_str(wbody, "via=", wvia, sizeof(wvia));
        if (!s_ok || !w_post_ok || strcmp(wvia, "live") != 0 || w_ms < 0 || w_ms > 700 || w_fill == 0) {
            fprintf(stderr, "FAIL: control POST is answered while the client write is stalled: attached=%d post_ok=%d via='%s' answered_in_ms=%ld (want <= 700) ring_fill_before=%zu (want > 0: the thread really was stalled)\n",
                    s_ok, w_post_ok, wvia, w_ms, w_fill);
            failures++;
        } else {
            printf("ok: control POST is answered while the client write is stalled (via=live in %ld ms, ring still held %zu bytes)\n", w_ms, w_fill);
        }
        if (stall_fd >= 0) close(stall_fd);
        usleep(200000);
        _test_ring_reset();
        g_boundary_at_pushed = -1;
        g_departed_client_generation = NO_CLIENT_GENERATION;
    }

    /* boundary-trifft-nachfolgeclient regression, direction (a) -- TOO
     * EARLY (the confirmed defect,
     * .planning/debug/boundary-trifft-nachfolgeclient.md): a boundary
     * planted while client A is attached must NOT be applied to client
     * B once B has taken over the slot in between planting and the ring
     * catching up to the marker -- B is already streaming bytes it is
     * entitled to (its own track), and closing it with a bounded EOF
     * meant for A truncates B's stream instead. This reproduces the
     * exact measured sequence: attach A, plant while A is attached,
     * takeover (B attaches, closing A's slot), THEN push past the
     * marker -- pre-fix, the marker fires against whichever fd is
     * CURRENTLY in client_fd (B), not the one it was planted for (A). */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";

        int afd = _test_connect_loopback(port);
        if (afd < 0) {
            fprintf(stderr, "FAIL: could not connect client A for takeover-boundary test\n");
            failures++;
        } else if (write(afd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(afd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach client A for takeover-boundary test\n");
            failures++;
            close(afd);
        } else {
            /* Confirm A is genuinely live before planting -- the marker
             * must be planted while A (not nobody) is attached, matching
             * the measured case exactly. */
            float preA[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
            int32_t expected_preA[4] = { 1073741824, -1073741824, 536870912, -536870912 };
            pa_stream_write(s, preA, sizeof(preA), NULL, 0, 0);
            unsigned char got_preA[16];
            int a_live = (_test_read_bytes(afd, got_preA, sizeof(got_preA), 3000) == 0
                          && memcmp(got_preA, expected_preA, sizeof(expected_preA)) == 0);
            if (!a_live) {
                fprintf(stderr, "FAIL: takeover-boundary test: client A never received its pre-pattern\n");
                failures++;
            }

            /* Plant the marker while A is the attached client. */
            int a_boundary_ok = _test_post_control(port, "/boundary");
            if (!a_boundary_ok) {
                fprintf(stderr, "FAIL: takeover-boundary test: POST /boundary (for A) did not return 200 OK\n");
                failures++;
            }

            /* Takeover: B attaches BEFORE the ring catches up to the
             * marker -- exactly the measured 10ms-after-plant window.
             * The takeover block closes A's fd server-side and promotes
             * B, bumping the generation counter (WR-11 takeover
             * semantics, pre-existing and unaffected by this fix). */
            int bfd = _test_connect_loopback(port);
            int b_attached = 0;
            if (bfd >= 0 && write(bfd, getReq, sizeof(getReq) - 1) >= 0
                && _test_read_header(bfd, 3000) == 0) {
                b_attached = 1;
            }
            if (!b_attached) {
                fprintf(stderr, "FAIL: takeover-boundary test: client B could not take over\n");
                failures++;
                if (bfd >= 0) close(bfd);
                close(afd);
            } else {
                /* A must have been closed server-side by the takeover --
                 * confirms this really IS a takeover, not two
                 * independently-served clients (setup validity check,
                 * not the regression assertion itself). */
                int a_closed = 0;
                for (int i = 0; i < 50 && !a_closed; i++) {
                    struct pollfd pfd; pfd.fd = afd; pfd.events = POLLIN;
                    if (poll(&pfd, 1, 20) > 0) {
                        unsigned char drain1;
                        ssize_t n = read(afd, &drain1, 1);
                        if (n == 0) a_closed = 1;
                    }
                }
                close(afd);
                if (!a_closed) {
                    fprintf(stderr, "FAIL: takeover-boundary test: client A was not superseded by B (setup invalid)\n");
                    failures++;
                }

                /* Push bytes AFTER B attached -- the ring is already
                 * caught up to A's marker (A's pre-pattern was fully
                 * consumed above), so this push crosses the marker on
                 * the very next drain tick, exactly like the measured
                 * case's next-track precursor. */
                float afterTakeover[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
                int32_t expected_afterTakeover[4] = { 2147483647, -2147483647, 0, 0 };
                pa_stream_write(s, afterTakeover, sizeof(afterTakeover), NULL, 0, 0);

                unsigned char got_b[16];
                int b_ok = (_test_read_bytes(bfd, got_b, sizeof(got_b), 1000) == 0);
                int b_matches = b_ok && (memcmp(got_b, expected_afterTakeover, sizeof(expected_afterTakeover)) == 0);

                if (!b_ok) {
                    fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction a): client B got EOF/error instead of its own bytes -- A's stale boundary closed B (THE CONFIRMED DEFECT)\n");
                    failures++;
                } else if (!b_matches) {
                    fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction a): client B's bytes mismatched (truncated by a stale boundary?)\n");
                    failures++;
                } else {
                    /* B must still be alive after the window the stale
                     * marker would have fired in -- a short poll with no
                     * data pending must NOT observe EOF. */
                    int b_spurious_eof = 0;
                    struct pollfd pfd; pfd.fd = bfd; pfd.events = POLLIN;
                    if (poll(&pfd, 1, 300) > 0) {
                        unsigned char probe;
                        ssize_t n = read(bfd, &probe, 1);
                        if (n == 0) b_spurious_eof = 1;
                    }
                    if (b_spurious_eof) {
                        fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction a): client B closed spuriously after receiving its own bytes\n");
                        failures++;
                    } else {
                        printf("ok: a boundary planted for a superseded client does not close its successor (boundary-trifft-nachfolgeclient direction a)\n");
                    }
                }
                close(bfd);
            }
        }
    }

    /* boundary-trifft-nachfolgeclient regression, direction (b) -- TOO
     * LATE/NEVER (the failure mode this fix must NOT introduce): once a
     * takeover has happened (bumping the generation counter, exactly as
     * every real track change does), a boundary planted for the
     * CURRENTLY attached client must still close it -- the fix's
     * generation MATCH branch must fire, not just its mismatch/discard
     * branch exercised above. Deliberately drives the generation counter
     * through an extra takeover FIRST (via a throwaway client) before
     * ever planting a marker, so the match check is exercised at a
     * non-trivial generation -- not only the degenerate generation==1
     * case the older, pre-existing "POST /boundary closes the client"
     * test above happens to cover. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";

        /* Throwaway client -- attached and immediately superseded, purely
         * to advance the generation counter past whatever it already was,
         * so the assertions below cannot pass "by accident" at a trivial
         * generation value. */
        int throwaway = _test_connect_loopback(port);
        if (throwaway >= 0) {
            if (write(throwaway, getReq, sizeof(getReq) - 1) >= 0) {
                _test_read_header(throwaway, 3000);
            }
        }

        int cfd = _test_connect_loopback(port);
        if (cfd < 0) {
            fprintf(stderr, "FAIL: could not connect client C for post-takeover boundary test\n");
            failures++;
            if (throwaway >= 0) close(throwaway);
        } else if (write(cfd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(cfd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach client C for post-takeover boundary test\n");
            failures++;
            close(cfd);
            if (throwaway >= 0) close(throwaway);
        } else {
            if (throwaway >= 0) close(throwaway);

            float preC[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
            int32_t expected_preC[4] = { 1073741824, -1073741824, 536870912, -536870912 };
            pa_stream_write(s, preC, sizeof(preC), NULL, 0, 0);
            unsigned char got_preC[16];
            if (_test_read_bytes(cfd, got_preC, sizeof(got_preC), 3000) != 0
                || memcmp(got_preC, expected_preC, sizeof(expected_preC)) != 0) {
                fprintf(stderr, "FAIL: post-takeover boundary test: client C pre-pattern never arrived or mismatched\n");
                failures++;
            }

            int c_boundary_ok = _test_post_control(port, "/boundary");
            if (!c_boundary_ok) {
                fprintf(stderr, "FAIL: post-takeover boundary test: POST /boundary did not return 200 OK\n");
                failures++;
            }

            float afterC[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
            pa_stream_write(s, afterC, sizeof(afterC), NULL, 0, 0);

            int got_eof = 0;
            unsigned char leftover[64];
            size_t leftover_n = 0;
            for (int i = 0; i < 100 && !got_eof; i++) {
                struct pollfd pfd; pfd.fd = cfd; pfd.events = POLLIN;
                if (poll(&pfd, 1, 10) > 0) {
                    ssize_t n = read(cfd, leftover + leftover_n, sizeof(leftover) - leftover_n);
                    if (n == 0) {
                        got_eof = 1;
                    } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                        got_eof = 1;
                    } else if (n > 0) {
                        leftover_n += (size_t)n;
                    }
                }
            }
            close(cfd);

            if (!got_eof) {
                fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction b): client C never reached EOF -- a matching-generation boundary failed to fire\n");
                failures++;
            } else if (leftover_n != 0) {
                fprintf(stderr, "FAIL: post-takeover boundary test: client C leaked %zu post-boundary byte(s)\n", leftover_n);
                failures++;
            } else {
                printf("ok: a boundary planted for the currently-attached client still closes it after a prior takeover (boundary-trifft-nachfolgeclient direction b)\n");
            }

            /* Fresh connection afterward must still stream normally --
             * the discard-on-mismatch branch (direction a) must not have
             * left g_boundary_at_pushed or g_client_generation in a state
             * that wedges the NEXT client either. 84-17: afterC (written
             * after the marker) now survives for this client and arrives
             * FIRST, then postC. */
            float postC[4] = { 0.125f, -0.125f, 0.0f, 1.0f };
            int32_t expected_afterAndPostC[8] = { 2147483647, -2147483647, 0, 0,
                                                  268435456, -268435456, 0, 2147483647 };
            pa_stream_write(s, postC, sizeof(postC), NULL, 0, 0);

            int dfd = _test_connect_loopback(port);
            if (dfd < 0) {
                fprintf(stderr, "FAIL: could not open fresh client after post-takeover boundary EOF\n");
                failures++;
            } else {
                unsigned char got_postC[32];
                if (write(dfd, getReq, sizeof(getReq) - 1) < 0
                    || _test_read_header(dfd, 3000) != 0
                    || _test_read_bytes(dfd, got_postC, sizeof(got_postC), 3000) != 0) {
                    fprintf(stderr, "FAIL: fresh client after post-takeover boundary EOF did not stream normally\n");
                    failures++;
                } else if (memcmp(got_postC, expected_afterAndPostC, sizeof(expected_afterAndPostC)) != 0) {
                    fprintf(stderr, "FAIL: fresh client after post-takeover boundary EOF received wrong bytes (84-17: afterC first, then postC)\n");
                    failures++;
                } else {
                    printf("ok: fresh client after post-takeover boundary EOF streams normally again\n");
                }
                close(dfd);
            }
        }
    }

    /* boundary-trifft-nachfolgeclient regression, direction (c) -- TOO
     * EARLY, sentinel case (client_fd < 0 at plant time). RENAMED and
     * RE-ASSERTED (.planning/debug/boundary-trifft-nachfolgeclient.md,
     * "WIEDERERÖFFNET" section) -- this was formerly the "no-client-at-
     * plant" test, and its ORIGINAL assertion ("the first attacher after
     * a client_fd < 0 plant must inherit the marker, D-04 rapid-skip
     * semantics preserved") is now known to be WRONG for THIS test's own
     * setup, per a live measurement made AFTER this test was first
     * written (2026-09-22 15:15:48, a positively-confirmed natural track
     * end): the predecessor here (client D, closed client-side by
     * direction (b) above) departs ABRUPTLY -- the server only notices
     * via a failed write (see the nudge loop below) -- and the
     * POST /boundary that follows, with client_fd < 0, is the one that
     * was meant to bound D's own stream. It is NOT the same shape as
     * D-04's rapid-skip test (below): D-04 has neither an attach nor a
     * detach anywhere between its two plants -- there is no predecessor
     * at all, so "last boundary wins" unconditionally is correct there.
     * This test's shape -- a REAL predecessor that departed abruptly,
     * then a plant with client_fd < 0 -- must instead behave like
     * direction (a): the marker belongs to the departed client and must
     * NOT be inherited by whoever attaches next (client E below). This
     * correction is the point of the g_departed_client_generation
     * mechanism -- see its doc comment above g_boundary_at_pushed for
     * the full story, including why a plain "bump on detach" generation
     * counter was considered and rejected (it cannot tell this case
     * apart from D-04's, since D-04 has no detach event to bump on
     * either). D-04 itself (below) is UNCHANGED by this correction --
     * this is a distinct precondition, not a relaxation of D-04's
     * guarantee. */
    {
        /* Deliberately does NOT force g_ring.client_connected = 0 here
         * (unlike every other test block's reset in this file) -- doing
         * so BEFORE the nudge below would make the nudge's very first
         * poll observe a value this test itself just zeroed, rather than
         * the server thread's genuine detection of dfd's closure. That
         * was this test's own first bug (caught by the ==EOF assertion
         * below failing even after the nudge was added): the nudge must
         * see the REAL 1->0 transition, so client_connected is left
         * alone until the nudge loop confirms it naturally. Ring content
         * (head/tail/fill) is still safe to reset immediately -- dfd is
         * already closed client-side, nobody genuine is reading it. */
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;

        /* This test's whole point is "no client attached AT PLANT TIME"
         * (client_fd < 0 inside _http_thread_fn) -- but direction (b)'s
         * `dfd` above was only closed CLIENT-side; the server thread only
         * notices via a failed WRITE (see the WR-11 test's identical
         * nudge earlier in this file), so client_fd can still be
         * stale-nonzero here. If it were, this plant would capture a
         * REAL (non-NO_CLIENT_GENERATION) generation instead, silently
         * testing the wrong precondition -- nudge until genuinely clean,
         * bounded so a real regression fails loudly instead of hanging. */
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
                fprintf(stderr, "FAIL: departed-client-at-plant test: server thread never noticed the previous test's client close (setup invalid)\n");
                failures++;
            }
            /* The nudge writes above perturbed the ring -- reset once
             * more so preE below starts from a byte-exact baseline. */
            pthread_mutex_lock(&g_ring.lock);
            g_ring.total_popped += (int64_t)g_ring.fill;
            g_ring.head = g_ring.tail = g_ring.fill = 0;
            pthread_mutex_unlock(&g_ring.lock);
        }

        static const char getReq[] = "GET /stream HTTP/1.0\r\n\r\n";

        /* Produced and planted with NO client attached at plant time --
         * but D (the just-departed predecessor) makes this an abrupt
         * departure, not a true "nobody ever" case. */
        float preE[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
        int32_t expected_preE[4] = { 1073741824, -1073741824, 536870912, -536870912 };
        pa_stream_write(s, preE, sizeof(preE), NULL, 0, 0);

        int e_boundary_ok = _test_post_control(port, "/boundary");
        if (!e_boundary_ok) {
            fprintf(stderr, "FAIL: departed-client-at-plant test: POST /boundary did not return 200 OK\n");
            failures++;
        }

        /* Produced AFTER the plant -- with the fix, E (below) must
         * receive BOTH preE and afterE: the marker is attributed to D's
         * departed generation, not to E, so it must be discarded rather
         * than applied when E attaches. */
        float afterE[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
        int32_t expected_afterE[4] = { 2147483647, -2147483647, 0, 0 };
        pa_stream_write(s, afterE, sizeof(afterE), NULL, 0, 0);

        /* A client attaches only AFTER both the plant and the post-plant
         * push above -- so its very first drain pass already sees
         * whatever the marker resolved to, same determinism reasoning as
         * the D-04 test. */
        int efd = _test_connect_loopback(port);
        if (efd < 0) {
            fprintf(stderr, "FAIL: could not connect client E for departed-client-at-plant test\n");
            failures++;
        } else if (write(efd, getReq, sizeof(getReq) - 1) < 0
                   || _test_read_header(efd, 3000) != 0) {
            fprintf(stderr, "FAIL: could not attach client E for departed-client-at-plant test\n");
            failures++;
            close(efd);
        } else {
            unsigned char got_e[32];
            int e_ok = (_test_read_bytes(efd, got_e, sizeof(got_e), 3000) == 0);
            int e_matches = e_ok
                && memcmp(got_e, expected_preE, sizeof(expected_preE)) == 0
                && memcmp(got_e + sizeof(expected_preE), expected_afterE, sizeof(expected_afterE)) == 0;

            if (!e_ok) {
                fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction c): client E got EOF/error instead of its own bytes -- D's departed-generation boundary closed E (THE REOPENED DEFECT, ordering 2)\n");
                failures++;
                close(efd);
            } else if (!e_matches) {
                fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction c): client E's bytes mismatched (truncated by a stale boundary?)\n");
                failures++;
                close(efd);
            } else {
                /* E must still be alive after the window the marker would
                 * have fired in -- a short poll with no data pending must
                 * NOT observe EOF (same check shape as direction (a)). */
                int e_spurious_eof = 0;
                struct pollfd pfd; pfd.fd = efd; pfd.events = POLLIN;
                if (poll(&pfd, 1, 300) > 0) {
                    unsigned char probe;
                    ssize_t n = read(efd, &probe, 1);
                    if (n == 0) e_spurious_eof = 1;
                }
                close(efd);
                if (e_spurious_eof) {
                    fprintf(stderr, "FAIL: boundary-trifft-nachfolgeclient regression (direction c): client E closed spuriously after receiving its own bytes\n");
                    failures++;
                } else {
                    printf("ok: a boundary planted right after its predecessor's abrupt departure is attributed to that predecessor, not inherited by the successor (boundary-trifft-nachfolgeclient direction c)\n");
                }
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
                    struct timeval ps;
                    gettimeofday(&ps, NULL);
                    for (;;) {
                        struct pollfd pfd; pfd.fd = sfd; pfd.events = POLLIN;
                        int rc = poll(&pfd, 1, 20);
                        if (rc > 0) {
                            ssize_t n = read(sfd, peek, sizeof(peek));
                            if (n > 0) { preLeaked = 1; break; }
                            if (n == 0) { preEof = 1; break; }
                        }
                        if (_elapsed_ms(&ps) >= 400) break;
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

    /* debug connect-seek-stoppt-wiedergabe (2026-09-24): a POST /seek-arm
     * that is still QUEUED -- in the listen backlog, or accepted but not
     * yet read in the pending slot -- when an unarmed pa_stream_flush()
     * raises g_flush_disconnect must be serviced BEFORE the disconnect
     * executes, and must cancel it. The flush already happened, so the
     * arm is consumed by it: no g_seek_flush_armed increment (else the
     * drain gate withholds audio until the 3 s TTL). Live shape (proxy
     * path, lavender-UAT 2026-09-24 08:04:14): LMS attaches its fresh
     * seek stream, sends the arm, then the WS seek; Soloist flushes 2-6 ms
     * after the arm was sent while this HTTP thread still sleeps in its
     * 50 ms empty-ring _ring_pop_timed(), and the loop-top flush-
     * disconnect closed the FRESH client before the arm was ever read.
     * Reproduced here with the same ordering: attached client, empty
     * ring, raw arm written without waiting for the 200, flush at once.
     * Variant 1 is the negative control -- the same sequence minus the
     * arm must still disconnect (D-12: unarmed flush = skip -> EOF). */
    for (int variant = 0; variant < 2; variant++) {
        int withArm = (variant == 0);
        const char *label = withArm ? "queued seek-arm" : "queued seek-arm negative control";

        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReqQ[] = "GET /stream HTTP/1.0\r\n\r\n";
        int qfd = _test_connect_loopback(port);
        if (qfd < 0 || write(qfd, getReqQ, sizeof(getReqQ) - 1) < 0
            || _test_read_header(qfd, 3000) != 0) {
            fprintf(stderr, "FAIL: %s: could not attach streaming client\n", label);
            failures++;
            if (qfd >= 0) close(qfd);
            continue;
        }

        float attachQ[2] = { 0.5f, -0.5f };
        int32_t expAttachQ[2];
        expAttachQ[0] = _test_f32_to_s32(attachQ[0]);
        expAttachQ[1] = _test_f32_to_s32(attachQ[1]);
        pa_stream_write(s, attachQ, sizeof(attachQ), NULL, 0, 0);
        unsigned char gotAttachQ[8];
        if (_test_read_bytes(qfd, gotAttachQ, sizeof(gotAttachQ), 3000) != 0
            || memcmp(gotAttachQ, expAttachQ, sizeof(expAttachQ)) != 0) {
            fprintf(stderr, "FAIL: %s: initial attach pattern never arrived or mismatched\n", label);
            failures++;
            close(qfd);
            continue;
        }

        /* Ring drained to empty -- let the HTTP thread settle into its
         * 50 ms empty-ring pop, the live stall this test reproduces. */
        usleep(15000);

        int afd = -1;
        if (withArm) {
            afd = _test_post_raw(port, "/seek-arm");   /* no wait for the 200 */
            if (afd < 0) {
                fprintf(stderr, "FAIL: %s: could not send raw POST /seek-arm\n", label);
                failures++;
                close(qfd);
                continue;
            }
        }
        pa_operation *qop = pa_stream_flush(s, NULL, NULL);
        if (qop) {
            pa_operation_unref(qop);
        }

        float postQ[4] = { 0.25f, -0.25f, 0.5f, -0.5f };
        int32_t expPostQ[4];
        for (int i = 0; i < 4; i++) {
            expPostQ[i] = _test_f32_to_s32(postQ[i]);
        }
        pa_stream_write(s, postQ, sizeof(postQ), NULL, 0, 0);

        if (withArm) {
            unsigned char gotPostQ[16];
            int gotPost = (_test_read_bytes(qfd, gotPostQ, sizeof(gotPostQ), 2000) == 0)
                          && memcmp(gotPostQ, expPostQ, sizeof(expPostQ)) == 0;
            int sawEof = _test_saw_eof(qfd, 400);
            int armOk = _test_read_control_ok(afd, 2000);
            int armedAfter = atomic_load(&g_seek_flush_armed);
            int flagAfter = g_flush_disconnect;
            pthread_mutex_lock(&g_ring.lock);
            int connected = g_ring.client_connected;
            pthread_mutex_unlock(&g_ring.lock);

            if (!armOk || !gotPost || sawEof || !connected || armedAfter != 0 || flagAfter) {
                fprintf(stderr, "FAIL: queued seek-arm at flush time did not cancel the flush-disconnect "
                                "(arm_200=%d post_pattern=%d eof=%d connected=%d armed_after=%d flush_flag=%d)\n",
                        armOk, gotPost, sawEof, connected, armedAfter, flagAfter);
                failures++;
            } else {
                printf("ok: queued seek-arm at flush time cancels the flush-disconnect (client kept, arm consumed, armed=0)\n");
            }
            close(afd);
        } else {
            int sawEof = _test_saw_eof(qfd, 1000);
            if (!sawEof) {
                fprintf(stderr, "FAIL: %s: unarmed flush did not disconnect the client (D-12)\n", label);
                failures++;
            } else {
                printf("ok: unarmed flush without a queued arm still disconnects (negative control)\n");
            }
        }
        close(qfd);
        g_seek_flush_armed = 0;
    }

    /* debug connect-seek-stoppt-wiedergabe (2026-09-24), deterministic
     * variants of the test above. There, the arm lands either in the
     * pending slot (HTTP thread was in poll() and accepted it) or in the
     * listen backlog (thread was asleep in the drain's empty-ring pop) --
     * whichever the scheduler picks. Both are forced here, one each, so
     * both halves of _flush_backlog_pass stay covered. The live failure
     * was the backlog case (repro1: client-attach, then "underflow: ring
     * empty", arm read 4 ms after the flush). Holding g_ring.lock parks
     * the HTTP thread inside the drain (poll() times out within 50 ms,
     * the pop then blocks on the lock):
     *   backlog -- the arm connects while the thread is parked, so it
     *              cannot be accepted and waits in the listen backlog;
     *   pending -- the arm connects first with no head, is accepted into
     *              the pending slot as an idle connection, and its head
     *              is written only while the thread is parked, so it is
     *              accepted-but-unread at the loop top.
     * The unarmed flush's g_flush_disconnect is then raised directly --
     * pa_stream_flush() itself takes g_ring.lock, and its ring flush
     * would be a no-op on this already-empty ring. */
    for (int kvariant = 0; kvariant < 2; kvariant++) {
        const char *klabel = (kvariant == 0) ? "backlog" : "pending";
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReqK[] = "GET /stream HTTP/1.0\r\n\r\n";
        static const char armReqK[] = "POST /seek-arm HTTP/1.0\r\nConnection: close\r\n\r\n";
        int kfd = _test_connect_loopback(port);
        if (kfd < 0 || write(kfd, getReqK, sizeof(getReqK) - 1) < 0
            || _test_read_header(kfd, 3000) != 0) {
            fprintf(stderr, "FAIL: %s seek-arm test: could not attach streaming client\n", klabel);
            failures++;
            if (kfd >= 0) close(kfd);
            continue;
        }
        float attachK[2] = { 0.5f, -0.5f };
        pa_stream_write(s, attachK, sizeof(attachK), NULL, 0, 0);
        unsigned char gotAttachK[8];
        int attached = (_test_read_bytes(kfd, gotAttachK, sizeof(gotAttachK), 3000) == 0);

        int afd = -1;
        int armWritten = 0;
        if (attached && kvariant == 0) {
            pthread_mutex_lock(&g_ring.lock);
            usleep(120000);                          /* HTTP thread parked in the drain */
            afd = _test_post_raw(port, "/seek-arm"); /* -> listen backlog */
            armWritten = (afd >= 0);
            g_flush_disconnect = 1;                  /* the unarmed flush's signal */
            pthread_mutex_unlock(&g_ring.lock);
        } else if (attached) {
            afd = _test_connect_loopback(port);      /* no head yet */
            usleep(150000);                          /* accepted into the pending slot, idle */
            pthread_mutex_lock(&g_ring.lock);
            usleep(120000);                          /* HTTP thread parked in the drain */
            armWritten = (afd >= 0
                          && write(afd, armReqK, sizeof(armReqK) - 1) == (ssize_t)(sizeof(armReqK) - 1));
            g_flush_disconnect = 1;                  /* the unarmed flush's signal */
            pthread_mutex_unlock(&g_ring.lock);
        }

        if (!armWritten) {
            fprintf(stderr, "FAIL: %s seek-arm test: setup failed (attached=%d arm_fd=%d)\n", klabel, attached, afd);
            failures++;
        } else {
            float postK[4] = { -0.25f, 0.25f, -0.5f, 0.5f };
            int32_t expPostK[4];
            for (int i = 0; i < 4; i++) {
                expPostK[i] = _test_f32_to_s32(postK[i]);
            }
            pa_stream_write(s, postK, sizeof(postK), NULL, 0, 0);

            unsigned char gotPostK[16];
            int gotPost = (_test_read_bytes(kfd, gotPostK, sizeof(gotPostK), 2000) == 0)
                          && memcmp(gotPostK, expPostK, sizeof(expPostK)) == 0;
            int sawEof = _test_saw_eof(kfd, 400);
            int armOk = _test_read_control_ok(afd, 2000);
            int armedAfter = atomic_load(&g_seek_flush_armed);
            int flagAfter = g_flush_disconnect;

            if (!armOk || !gotPost || sawEof || armedAfter != 0 || flagAfter) {
                fprintf(stderr, "FAIL: seek-arm in the %s at flush-disconnect time did not cancel it "
                                "(arm_200=%d post_pattern=%d eof=%d armed_after=%d flush_flag=%d)\n",
                        klabel, armOk, gotPost, sawEof, armedAfter, flagAfter);
                failures++;
            } else {
                printf("ok: seek-arm in the %s at flush-disconnect time cancels it (backlog pass)\n", klabel);
            }
        }
        if (afd >= 0) close(afd);
        close(kfd);
        g_flush_disconnect = 0;
        g_seek_flush_armed = 0;
    }

    /* debug connect-seek-stoppt-wiedergabe (2026-09-24): the second way
     * to lose an arm -- a newer connection preempting a pending slot
     * whose request head was never read (82-16 todo, 82-G1 Vorbefund:
     * 6/6 async arms lost this way). POST /seek-arm immediately followed
     * by GET /stream: the pending arm must be read and served before the
     * GET takes the slot; the GET still takes over, the arm is honored
     * by the next flush, and a further unarmed flush still disconnects. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReqP[] = "GET /stream HTTP/1.0\r\n\r\n";
        int p1 = _test_connect_loopback(port);
        if (p1 < 0 || write(p1, getReqP, sizeof(getReqP) - 1) < 0
            || _test_read_header(p1, 3000) != 0) {
            fprintf(stderr, "FAIL: pending-slot arm test: could not attach first streaming client\n");
            failures++;
            if (p1 >= 0) close(p1);
        } else {
            float attachP[2] = { 0.5f, -0.5f };
            pa_stream_write(s, attachP, sizeof(attachP), NULL, 0, 0);
            unsigned char gotAttachP[8];
            int attached = (_test_read_bytes(p1, gotAttachP, sizeof(gotAttachP), 3000) == 0);
            usleep(15000);

            int afd = attached ? _test_post_raw(port, "/seek-arm") : -1;
            int p2 = (afd >= 0) ? _test_connect_loopback(port) : -1;
            if (!attached || afd < 0 || p2 < 0 || write(p2, getReqP, sizeof(getReqP) - 1) < 0) {
                fprintf(stderr, "FAIL: pending-slot arm test: setup failed (attached=%d arm_fd=%d get_fd=%d)\n",
                        attached, afd, p2);
                failures++;
            } else {
                int armOk = _test_read_control_ok(afd, 2000);
                int p2hdr = (_test_read_header(p2, 3000) == 0);
                int armedNow = atomic_load(&g_seek_flush_armed);

                if (!armOk) {
                    fprintf(stderr, "FAIL: pending POST /seek-arm dropped by racing GET (arm_200=0 get_promoted=%d armed=%d)\n",
                            p2hdr, armedNow);
                    failures++;
                } else if (!p2hdr) {
                    fprintf(stderr, "FAIL: pending-slot arm test: racing GET was not promoted after the arm was served\n");
                    failures++;
                } else if (armedNow != 1) {
                    fprintf(stderr, "FAIL: pending-slot arm test: armed=%d after one served arm (expected 1)\n", armedNow);
                    failures++;
                } else {
                    /* Armed flush: consumed, the promoted GET stays. */
                    pa_operation *pop1 = pa_stream_flush(s, NULL, NULL);
                    if (pop1) pa_operation_unref(pop1);
                    float postP[4] = { 0.125f, -0.125f, 0.375f, -0.375f };
                    int32_t expPostP[4];
                    for (int i = 0; i < 4; i++) {
                        expPostP[i] = _test_f32_to_s32(postP[i]);
                    }
                    pa_stream_write(s, postP, sizeof(postP), NULL, 0, 0);
                    unsigned char gotPostP[16];
                    int gotPost = (_test_read_bytes(p2, gotPostP, sizeof(gotPostP), 2000) == 0)
                                  && memcmp(gotPostP, expPostP, sizeof(expPostP)) == 0;
                    int earlyEof = _test_saw_eof(p2, 300);

                    /* Unarmed flush: D-12 still disconnects. */
                    pa_operation *pop2 = pa_stream_flush(s, NULL, NULL);
                    if (pop2) pa_operation_unref(pop2);
                    int lateEof = _test_saw_eof(p2, 1000);

                    if (!gotPost || earlyEof) {
                        fprintf(stderr, "FAIL: pending-slot arm test: armed flush did not keep the promoted GET streaming "
                                        "(post_pattern=%d eof=%d)\n", gotPost, earlyEof);
                        failures++;
                    } else if (!lateEof) {
                        fprintf(stderr, "FAIL: pending-slot arm test: later unarmed flush did not disconnect (D-12)\n");
                        failures++;
                    } else {
                        printf("ok: pending seek-arm survives a racing GET (served before preemption, honored by the next flush)\n");
                    }
                }
            }
            if (afd >= 0) close(afd);
            if (p2 >= 0) close(p2);
            close(p1);
        }
        g_seek_flush_armed = 0;
    }

    /* debug connect-seek-stoppt-wiedergabe (2026-09-24), neighbor of the
     * queued seek-arm test: the flush-disconnect backlog pass reads every
     * queued connection before the disconnect, but only a /seek-arm may
     * act there. A POST /boundary queued at the same moment (an app skip
     * flushes AND fires WS track_changed) must survive the pass -- its
     * head is already read, so the peer's FIN must not be mistaken for a
     * dead connection -- and must still be served AFTER the disconnect,
     * exactly as before the pass existed: 200 OK, the unarmed flush still
     * disconnects the client, and the marker is planted (the disconnect
     * clears g_boundary_at_pushed, so a planted marker proves the order
     * disconnect-then-boundary). */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReqB[] = "GET /stream HTTP/1.0\r\n\r\n";
        int bfd = _test_connect_loopback(port);
        if (bfd < 0 || write(bfd, getReqB, sizeof(getReqB) - 1) < 0
            || _test_read_header(bfd, 3000) != 0) {
            fprintf(stderr, "FAIL: queued boundary test: could not attach streaming client\n");
            failures++;
            if (bfd >= 0) close(bfd);
        } else {
            float attachB[2] = { 0.5f, -0.5f };
            pa_stream_write(s, attachB, sizeof(attachB), NULL, 0, 0);
            unsigned char gotAttachB[8];
            int attached = (_test_read_bytes(bfd, gotAttachB, sizeof(gotAttachB), 3000) == 0);
            usleep(15000);

            int bpost = attached ? _test_post_raw(port, "/boundary") : -1;
            if (bpost < 0) {
                fprintf(stderr, "FAIL: queued boundary test: setup failed (attached=%d)\n", attached);
                failures++;
            } else {
                /* Raw POST, then close our write side like _loopbackPost
                 * does (it closes right after its one syswrite) -- the
                 * FIN is what an extra read after the head would see. */
                shutdown(bpost, SHUT_WR);
                pa_operation *bop = pa_stream_flush(s, NULL, NULL);
                if (bop) pa_operation_unref(bop);

                int sawEof = _test_saw_eof(bfd, 1000);
                int boundaryOk = _test_read_control_ok(bpost, 2000);
                int64_t planted = g_boundary_at_pushed;

                if (!boundaryOk || !sawEof || planted < 0) {
                    fprintf(stderr, "FAIL: queued POST /boundary at flush time was lost or reordered by the backlog pass "
                                    "(boundary_200=%d client_eof=%d planted=%lld)\n",
                            boundaryOk, sawEof, (long long)planted);
                    failures++;
                } else {
                    printf("ok: queued boundary at flush time survives the backlog pass (served after the disconnect)\n");
                }
                close(bpost);
            }
            close(bfd);
        }
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;
    }

    /* debug connect-skip-prev-ton-bleibt (2026-09-24), branch B, user
     * decision 2A: an UNARMED flush (a skip to another title -- LMS
     * "previous"/"next" in Connect, or an app skip) closes the attached
     * client via the flush-disconnect path; the old title's POST /boundary
     * (sent on WS track_changed, i.e. AFTER the flush) then arrives with
     * NO client attached, at a ring position that already holds the new
     * title's first bytes. Live 2026-09-24 12:01:37 / 12:10:00: planted
     * `gen=-1 via=none`, inherited by LMS' fresh stream, which was closed
     * after 16384 bytes -> STOPPED. The marker belongs to the departed
     * (flush-disconnected) client only: the successor must receive the
     * bytes on both sides of the mark and stay open. Second half: the
     * successor's OWN later boundary (planted while it is attached) still
     * closes it -- the departed record must not over-discard. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.total_popped += (int64_t)g_ring.fill;
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;

        static const char getReqS[] = "GET /stream HTTP/1.0\r\n\r\n";
        int sfd = _test_connect_loopback(port);
        if (sfd < 0 || write(sfd, getReqS, sizeof(getReqS) - 1) < 0
            || _test_read_header(sfd, 3000) != 0) {
            fprintf(stderr, "FAIL: boundary-after-flush-disconnect test: could not attach the old title's client\n");
            failures++;
            if (sfd >= 0) close(sfd);
        } else {
            float oldS[2] = { 0.5f, -0.5f };
            pa_stream_write(s, oldS, sizeof(oldS), NULL, 0, 0);
            unsigned char gotOldS[8];
            int oldDraining = (_test_read_bytes(sfd, gotOldS, sizeof(gotOldS), 3000) == 0);

            /* The skip: unarmed flush -> flush-disconnect of the old client. */
            pa_operation *sop = pa_stream_flush(s, NULL, NULL);
            if (sop) pa_operation_unref(sop);
            int oldClosed = oldDraining && _test_saw_eof(sfd, 1000);
            close(sfd);

            /* The new title's first bytes land in the ring with nobody
             * attached; THEN the old title's /boundary arrives. */
            float preS[4] = { 0.5f, -0.5f, 0.25f, -0.25f };
            int32_t expected_preS[4] = { 1073741824, -1073741824, 536870912, -536870912 };
            pa_stream_write(s, preS, sizeof(preS), NULL, 0, 0);
            int sBoundaryOk = oldClosed && _test_post_control(port, "/boundary");
            float afterS[4] = { 1.0f, -1.0f, 0.0f, 0.0f };
            int32_t expected_afterS[4] = { 2147483647, -2147483647, 0, 0 };
            pa_stream_write(s, afterS, sizeof(afterS), NULL, 0, 0);

            if (!oldDraining || !oldClosed || !sBoundaryOk) {
                fprintf(stderr, "FAIL: boundary-after-flush-disconnect test: setup failed (draining=%d closed=%d boundary_200=%d)\n",
                        oldDraining, oldClosed, sBoundaryOk);
                failures++;
            } else {
                int nfd = _test_connect_loopback(port);
                if (nfd < 0 || write(nfd, getReqS, sizeof(getReqS) - 1) < 0
                    || _test_read_header(nfd, 3000) != 0) {
                    fprintf(stderr, "FAIL: boundary-after-flush-disconnect test: could not attach the new title's client\n");
                    failures++;
                    if (nfd >= 0) close(nfd);
                } else {
                    unsigned char gotN[32];
                    int nOk = (_test_read_bytes(nfd, gotN, sizeof(gotN), 3000) == 0);
                    int nMatches = nOk
                        && memcmp(gotN, expected_preS, sizeof(expected_preS)) == 0
                        && memcmp(gotN + sizeof(expected_preS), expected_afterS, sizeof(expected_afterS)) == 0;
                    if (!nOk || !nMatches) {
                        fprintf(stderr, "FAIL: a boundary planted after an unarmed flush-disconnect closed the NEW title's client "
                                        "(got_32_bytes=%d bytes_match=%d) -- connect-skip-prev-ton-bleibt branch B\n",
                                nOk, nMatches);
                        failures++;
                        close(nfd);
                    } else {
                        /* The successor's own boundary, planted while it
                         * is attached, still bounds it. */
                        float liveS1[2] = { 0.5f, -0.5f };
                        pa_stream_write(s, liveS1, sizeof(liveS1), NULL, 0, 0);
                        unsigned char gotLive1[8];
                        int live1 = (_test_read_bytes(nfd, gotLive1, sizeof(gotLive1), 3000) == 0);
                        int liveBoundaryOk = live1 && _test_post_control(port, "/boundary");
                        float liveS2[2] = { 0.25f, -0.25f };
                        pa_stream_write(s, liveS2, sizeof(liveS2), NULL, 0, 0);
                        int nClosedAtOwnBoundary = liveBoundaryOk && _test_saw_eof(nfd, 1000);
                        close(nfd);
                        if (!nClosedAtOwnBoundary) {
                            fprintf(stderr, "FAIL: boundary-after-flush-disconnect test: the successor's OWN boundary did not close it "
                                            "(live_bytes=%d boundary_200=%d) -- over-discard\n", live1, liveBoundaryOk);
                            failures++;
                        } else {
                            printf("ok: a boundary planted after an unarmed flush-disconnect belongs to the departed client -- "
                                   "the next title's client keeps streaming, its own boundary still closes it\n");
                        }
                    }
                }
            }
        }
        /* Leave no marker/record behind for the tests below. */
        g_boundary_at_pushed = -1;
        g_seek_flush_armed = 0;
        g_departed_client_generation = NO_CLIENT_GENERATION;
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
                    struct timeval ps;
                    gettimeofday(&ps, NULL);
                    for (;;) {
                        struct pollfd pfd; pfd.fd = lfd; pfd.events = POLLIN;
                        int rc = poll(&pfd, 1, 20);
                        if (rc > 0) {
                            ssize_t n = read(lfd, peek, sizeof(peek));
                            if (n > 0) { leaked = 1; break; }
                            if (n == 0) { sawEofWhileArmed = 1; break; }
                        }
                        if (_elapsed_ms(&ps) >= 400) break;
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
                        struct timeval ps;
                        gettimeofday(&ps, NULL);
                        for (;;) {
                            struct pollfd pfd; pfd.fd = c2fd; pfd.events = POLLIN;
                            int rc = poll(&pfd, 1, 20);
                            if (rc > 0) {
                                ssize_t n = read(c2fd, peek, sizeof(peek));
                                if (n > 0) { preLeaked = 1; break; }
                                if (n == 0) { preEof = 1; break; }
                            }
                            if (_elapsed_ms(&ps) >= 400) break;
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

    /* 84-17 backpressure: a full ring never discards -- the writer waits.
     * Shape taken from the long-tail measurement: the ring sat at 80240 B
     * free (7056000 - 6975760) when the daemon wrote one 81920 B chunk
     * anyway; 1680 B of the OLDEST audio were thrown away. Here: fill to
     * 80240 B free with no consumer, one 81920 B write from a thread, then
     * attach a consumer. */
    {
        pthread_mutex_lock(&g_ring.lock);
        g_ring.head = g_ring.tail = g_ring.fill = 0;
        g_ring.client_connected = 0;
        pthread_mutex_unlock(&g_ring.lock);
        _test_ring_reset();
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        pa_sample_format_t savedFmt = s->sample_spec.format;
        s->sample_spec.format = PA_SAMPLE_S32LE;

        int32_t seq = 0, expect = 0;
        const size_t freeAtStall = 80240, chunkBytes = 81920;
        size_t prefill = (size_t)RING_CAPACITY - freeAtStall;
        int32_t *pre = _test_seq_buf(prefill, &seq);
        int32_t *chunk = _test_seq_buf(chunkBytes, &seq);
        int64_t drops0 = _test_drops();
        if (!pre || !chunk) {
            fprintf(stderr, "FAIL: malloc for the backpressure test\n");
            failures++;
        } else {
            pa_stream_write(s, pre, prefill, NULL, 0, 0);
            /* physical free space (the daemon is told 0 here: it is inside the reserve; this
             * case is the BACKSTOP -- a write that ignores the signal still loses nothing) */
            size_t freeNow = (size_t)RING_CAPACITY - _test_fill();
            _test_writer_t w = { .s = s, .data = chunk, .nbytes = chunkBytes };
            atomic_init(&w.done, 0);
            pthread_t th;
            pthread_create(&th, NULL, _test_writer_thread, &w);
            usleep(400000);
            int stillWaiting = !atomic_load(&w.done);
            int64_t dropsMid = _test_drops() - drops0;
            long bad = 0;
            size_t popped = _test_consume_all(&w.done, &expect, &bad, 8000);
            pthread_join(th, NULL);
            int64_t dropsEnd = _test_drops() - drops0;
            if (freeNow != freeAtStall || !stillWaiting || dropsMid != 0 || dropsEnd != 0
                || popped != prefill + chunkBytes || bad != 0 || w.elapsed_ms < 300) {
                fprintf(stderr, "FAIL: full ring: the writer waits and nothing is discarded: physical_free_before_write=%zu (want %zu) still_waiting_after_400ms=%d drops_mid=%lld drops_end=%lld popped=%zu (want %zu) mismatches=%ld write_took_ms=%ld\n",
                        freeNow, freeAtStall, stillWaiting, (long long)dropsMid, (long long)dropsEnd,
                        popped, prefill + chunkBytes, bad, w.elapsed_ms);
                failures++;
            } else {
                printf("ok: full ring: the writer waits and nothing is discarded (81920 B write into 80240 B free waited %ldms, drops 0, %zu bytes consumed in order)\n",
                       w.elapsed_ms, popped);
            }
        }
        free(pre);
        free(chunk);
        s->sample_spec.format = savedFmt;
        _test_ring_reset();
    }

    /* 84-17: a flush while the writer waits releases it and the stale
     * chunk is abandoned (audio of the old title must not reappear after a
     * skip). The armed flush is consumed, so no client disconnect flag is
     * left behind for later cases. */
    {
        _test_ring_reset();
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        pa_sample_format_t savedFmt = s->sample_spec.format;
        s->sample_spec.format = PA_SAMPLE_S32LE;
        int32_t seq = 0;
        const size_t freeAtStall = 80240, chunkBytes = 81920;
        size_t prefill = (size_t)RING_CAPACITY - freeAtStall;
        int32_t *pre = _test_seq_buf(prefill, &seq);
        int32_t *chunk = _test_seq_buf(chunkBytes, &seq);
        if (!pre || !chunk) {
            fprintf(stderr, "FAIL: malloc for the flush-release test\n");
            failures++;
        } else {
            pa_stream_write(s, pre, prefill, NULL, 0, 0);
            _test_writer_t w = { .s = s, .data = chunk, .nbytes = chunkBytes };
            atomic_init(&w.done, 0);
            pthread_t th;
            pthread_create(&th, NULL, _test_writer_thread, &w);
            usleep(300000);
            int waitingBefore = !atomic_load(&w.done);
            atomic_store(&g_seek_flush_armed, 1);
            struct timeval t0, now;
            gettimeofday(&t0, NULL);
            pa_stream_flush(s, NULL, NULL);
            long released_ms = -1;
            for (;;) {
                gettimeofday(&now, NULL);
                long ms = (now.tv_sec - t0.tv_sec) * 1000 + (now.tv_usec - t0.tv_usec) / 1000;
                if (atomic_load(&w.done)) { released_ms = ms; break; }
                if (ms > 3000) break;
                usleep(5000);
            }
            if (released_ms >= 0) pthread_join(th, NULL);
            usleep(150000);
            size_t fillAfter = _test_fill();
            int64_t dropsAfter = _test_drops();
            /* the ring is usable again right after */
            int32_t seq2 = 1000;
            int32_t *fresh = _test_seq_buf(4096, &seq2);
            if (fresh) pa_stream_write(s, fresh, 4096, NULL, 0, 0);
            free(fresh);
            size_t fillFresh = _test_fill();
            if (!waitingBefore || released_ms < 0 || released_ms > 1000 || fillAfter != 0 || fillFresh != 4096) {
                fprintf(stderr, "FAIL: flush releases a waiting writer and abandons the stale chunk: waiting_before_flush=%d released_after_ms=%ld fill_after_flush=%zu (want 0) fill_after_fresh_write=%zu (want 4096) drops_total=%lld\n",
                        waitingBefore, released_ms, fillAfter, fillFresh, (long long)dropsAfter);
                failures++;
                if (released_ms < 0) {
                    /* do not leave the writer thread blocked: let it finish by consuming */
                    _test_ring_reset();
                    pthread_join(th, NULL);
                }
            } else {
                printf("ok: flush releases a waiting writer and abandons the stale chunk (released in %ldms, ring empty afterwards, fresh write accepted)\n", released_ms);
            }
        }
        free(pre);
        free(chunk);
        s->sample_spec.format = savedFmt;
        atomic_store(&g_seek_flush_armed, 0);
        _test_ring_reset();
    }

    /* 84-17: the safety ceiling. With nobody ever consuming, a waiting
     * writer is released after SPOTON_FAKEPULSE_WRITE_WAIT_MS; the bytes it
     * could not place are refused AND counted (drops=), never silent. */
    {
        _test_ring_reset();
        setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "300", 1);
        pa_sample_format_t savedFmt = s->sample_spec.format;
        s->sample_spec.format = PA_SAMPLE_S32LE;
        int32_t seq = 0;
        int32_t *full = _test_seq_buf((size_t)RING_CAPACITY, &seq);
        const size_t overBytes = 100000;
        int32_t *over = _test_seq_buf(overBytes, &seq);
        if (!full || !over) {
            fprintf(stderr, "FAIL: malloc for the ceiling test\n");
            failures++;
        } else {
            pa_stream_write(s, full, (size_t)RING_CAPACITY, NULL, 0, 0);
            size_t freeFull = pa_stream_writable_size(s);
            int64_t drops0 = _test_drops();
            struct timeval t0, t1;
            gettimeofday(&t0, NULL);
            pa_stream_write(s, over, overBytes, NULL, 0, 0);
            gettimeofday(&t1, NULL);
            long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
            int64_t dd = _test_drops() - drops0;
            size_t fillAfter = _test_fill();
            if (freeFull != 0 || ms < 250 || ms > 3000 || dd != (int64_t)overBytes || fillAfter != (size_t)RING_CAPACITY) {
                fprintf(stderr, "FAIL: write ceiling releases a stuck writer and counts the refusal: writable_size_when_full=%zu (want 0) write_took_ms=%ld (want 250..3000) drops_delta=%lld (want %zu) fill_after=%zu (want %d)\n",
                        freeFull, ms, (long long)dd, overBytes, fillAfter, RING_CAPACITY);
                failures++;
            } else {
                printf("ok: write ceiling releases a stuck writer and counts the refusal (waited %ldms, %zu bytes counted in drops, ring content untouched)\n", ms, overBytes);
            }
        }
        free(full);
        free(over);
        s->sample_spec.format = savedFmt;
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        _test_ring_reset();
    }

    /* 84-17: writable_size tells the daemon "no room". It reports the free
     * space minus a reserve (the daemon writes one whole chunk whenever the
     * reported size is > 0, whatever its size -- seen live: a 7136 B write at
     * 5456 B free) and 0 once the free space is at or below the reserve, so a
     * daemon that follows the signal stops BEFORE the ring is physically full
     * and its last chunk lands in the reserve instead of waiting in the shim. */
    {
        _test_ring_reset();
        pa_sample_format_t savedFmt = s->sample_spec.format;
        s->sample_spec.format = PA_SAMPLE_S32LE;
        int32_t seq = 0;
        size_t cap = (size_t)RING_CAPACITY, M = _TEST_WRITE_MARGIN;
        size_t steps[3] = { 4000, 0, 0 };
        steps[1] = cap - M - 8000 - steps[0];       /* reported = 8000 */
        steps[2] = 8000 + M;                        /* reported = 0, ring physically full */
        size_t want[4] = { cap - M, cap - M - 4000, 8000, 0 };
        size_t seen[4];
        size_t expectFill = 0;
        seen[0] = pa_stream_writable_size(s);
        int ok = (seen[0] == want[0]);
        for (int i = 0; i < 3 && ok; i++) {
            int32_t *b2 = _test_seq_buf(steps[i], &seq);
            if (!b2) { ok = 0; break; }
            pa_stream_write(s, b2, steps[i], NULL, 0, 0);
            free(b2);
            expectFill += steps[i];
            seen[i + 1] = pa_stream_writable_size(s);
            if (seen[i + 1] != want[i + 1]) ok = 0;
        }
        if (!ok) {
            fprintf(stderr, "FAIL: writable_size reports the free space minus the reserve: seen %zu %zu %zu %zu (want %zu %zu %zu %zu)\n",
                    seen[0], seen[1], seen[2], seen[3], want[0], want[1], want[2], want[3]);
            failures++;
        } else {
            printf("ok: writable_size reports the free space minus the reserve (0 once only the reserve is left)\n");
        }
        s->sample_spec.format = savedFmt;
        _test_ring_reset();
    }

    /* 84-17: the daemon's write pattern with NOBODY consuming (the unread gap):
     * it writes one 8192 B chunk whenever writable_size > 0 and waits at 0. With
     * the reserve it stops before the ring is physically full, its last chunk
     * lands in the reserve, it never waits inside the shim and nothing is
     * discarded or refused. */
    {
        _test_ring_reset();
        setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "1000", 1);
        pa_sample_format_t savedFmt = s->sample_spec.format;
        s->sample_spec.format = PA_SAMPLE_S32LE;
        int32_t seq = 0;
        int32_t *chunk = _test_seq_buf(8192, &seq);
        int64_t drops0 = _test_drops();
        struct timeval t0, t1;
        gettimeofday(&t0, NULL);
        long writes = 0;
        while (chunk && pa_stream_writable_size(s) > 0 && writes < 2000) {
            pa_stream_write(s, chunk, 8192, NULL, 0, 0);
            writes++;
        }
        gettimeofday(&t1, NULL);
        long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
        size_t fillEnd = _test_fill();
        int64_t dd = _test_drops() - drops0;
        size_t rep = pa_stream_writable_size(s);
        if (!chunk || ms > 600 || dd != 0 || rep != 0 || fillEnd > (size_t)RING_CAPACITY
            || fillEnd < (size_t)RING_CAPACITY - _TEST_WRITE_MARGIN) {
            fprintf(stderr, "FAIL: a daemon that stops at writable_size 0 never waits in the shim and loses nothing: loop_took_ms=%ld (want <= 600) drops_delta=%lld (want 0) writes=%ld fill_end=%zu (want %zu..%d) writable_at_end=%zu (want 0)\n",
                    ms, (long long)dd, writes, fillEnd, (size_t)RING_CAPACITY - _TEST_WRITE_MARGIN, RING_CAPACITY, rep);
            failures++;
        } else {
            printf("ok: a daemon that stops at writable_size 0 never waits in the shim and loses nothing (%ld writes in %ldms, ring %zu of %d, drops 0)\n",
                   writes, ms, fillEnd, RING_CAPACITY);
        }
        free(chunk);
        s->sample_spec.format = savedFmt;
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        _test_ring_reset();
    }

    /* Over-capacity write with no consumer (was "drop-oldest", 84-17: the
     * oldest bytes are never discarded any more). Force client_connected=0
     * and an empty ring directly (same translation unit), shorten the write
     * ceiling, then push far more than RING_CAPACITY worth of samples: the
     * call returns after the ceiling (bounded, never forever) with the ring
     * left completely (but only) full of the FIRST capacity bytes. */
    {
        setenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS", "200", 1);
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

            unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
            if (ms > 5000) {
                fprintf(stderr, "FAIL: pa_stream_write blocked for %ldms with no client connected\n", ms);
                failures++;
            } else if (fillAfter != RING_CAPACITY) {
                fprintf(stderr, "FAIL: ring not full after over-capacity write (fill=%zu, capacity=%d)\n",
                        fillAfter, RING_CAPACITY);
                failures++;
            } else {
                printf("ok: over-capacity write with no client returns at the ceiling, ring full of the first bytes (took %ldms, ring full=%zu)\n", ms, fillAfter);
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

        if (before != (size_t)RING_CAPACITY - _TEST_WRITE_MARGIN) {
            fprintf(stderr, "FAIL: writable_size before write != capacity - write margin (before=%zu)\n", before);
            failures++;
        } else if (!(after < before)) {
            fprintf(stderr, "FAIL: writable_size did not shrink (before=%zu after=%zu)\n", before, after);
            failures++;
        } else {
            printf("ok: writable_size shrinks as the ring fills (before=%zu after=%zu)\n", before, after);
        }
    }

    /* ================================================================== */
    /* 84-20 (Q2): the virtual sink. A virtual sink of T ms makes the     */
    /* shim behave like a PulseAudio sink of that depth: writable_size    */
    /* shrinks as audio is written and regrows at the wall-clock rate     */
    /* while the stream is uncorked, a flush empties it, underflow and    */
    /* read_index/sink_usec follow it. Every case here sets its own T and */
    /* its own frozen clock, and restores T 0 / the real clock.           */
    /* ================================================================== */

    /* writable_size on a corked stream, then uncorked (cases 1-3). */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 1000, 1);
        size_t w0 = pa_stream_writable_size(s);
        _test_vsink_write_n(s, 352800);
        size_t w1 = pa_stream_writable_size(s);
        if (w0 != 352800 || w1 != 0) {
            fprintf(stderr, "FAIL: vsink: writable_size reaches 0 after T ms written while corked (before=%zu want 352800, after=%zu want 0)\n", w0, w1);
            failures++;
        } else {
            printf("ok: vsink: writable_size reaches 0 after T ms written while corked\n");
        }

        _test_vsink_clock_advance_ms(2000);
        size_t w2 = pa_stream_writable_size(s);
        if (w2 != 0) {
            fprintf(stderr, "FAIL: vsink: a corked stream keeps writable_size at 0 while the clock runs (after 2 s corked: %zu want 0)\n", w2);
            failures++;
        } else {
            printf("ok: vsink: a corked stream keeps writable_size at 0 while the clock runs\n");
        }

        _test_vsink_cork(s, 0);
        _test_vsink_clock_advance_ms(250);
        size_t w3 = pa_stream_writable_size(s);
        _test_vsink_clock_advance_ms(2000);
        size_t w4 = pa_stream_writable_size(s);
        size_t realMax = (size_t)RING_CAPACITY - _test_fill() - _TEST_WRITE_MARGIN;
        size_t want4 = realMax < 352800 ? realMax : 352800;
        if (w3 != 88200 || w4 != want4) {
            fprintf(stderr, "FAIL: vsink: an uncorked stream regains writable_size at the wall-clock rate (250 ms uncorked: %zu want 88200; past T: %zu want %zu)\n", w3, w4, want4);
            failures++;
        } else {
            printf("ok: vsink: an uncorked stream regains writable_size at the wall-clock rate\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* The drain clock restarts on every cork change (MUST-FIX c): T written
     * while corked, the clock runs 5 s with NO call into the shim in between
     * (so no settle refreshes the shim's own reference), then uncork, 250 ms,
     * ONE read. A build without the cork-site reset reads the 5.25 s drained
     * (about 1.85 MB), and reading at the uncork instant would not show it. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 10000, 1);
        _test_vsink_write_n(s, 3528000);
        _test_vsink_clock_advance_ms(5000);
        _test_vsink_cork(s, 0);
        _test_vsink_clock_advance_ms(250);
        size_t wq = pa_stream_writable_size(s);
        if (wq != 88200) {
            fprintf(stderr, "FAIL: vsink: uncork restarts the drain clock so a corked interval never drains (read %zu want 88200)\n", wq);
            failures++;
        } else {
            printf("ok: vsink: uncork restarts the drain clock so a corked interval never drains\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* A flush empties the virtual sink (and the ring). */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 1000, 1);
        _test_vsink_write_n(s, 176400);
        size_t wb = pa_stream_writable_size(s);
        _test_vsink_flush(s);
        size_t wa = pa_stream_writable_size(s);
        size_t realMax = (size_t)RING_CAPACITY - _test_fill() - _TEST_WRITE_MARGIN;
        size_t wantA = realMax < 352800 ? realMax : 352800;
        if (wb != 176400 || wa != wantA) {
            fprintf(stderr, "FAIL: vsink: flush empties the virtual sink (before the flush %zu want 176400; after %zu want %zu)\n", wb, wa, wantA);
            failures++;
        } else {
            printf("ok: vsink: flush empties the virtual sink\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* read_index and sink_usec include the virtual sink (F32, uncorked, the
     * ring drained like a client would, then 1 s of drain, then fresh data
     * left in the ring). */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 5000, 0);
        _test_vsink_write_n(s, 1000000);
        size_t popped = _test_vsink_pop(1000000);
        _test_vsink_clock_advance_ms(1000);
        _test_vsink_update_timing(s);
        long long bw1 = (long long)s->bytes_written;
        long long q1 = 1000000LL - 352800LL;
        long long ri1 = bw1 - 0 - q1;
        long long su1 = ((0 + q1) * 1000000LL) / 352800LL;
        long long gotRi1 = (long long)s->timing.read_index;
        long long gotSu1 = (long long)s->timing.sink_usec;

        _test_vsink_write_n(s, 100000);
        _test_vsink_update_timing(s);
        long long bw2 = (long long)s->bytes_written;
        long long q2 = q1 + 100000LL;
        long long ri2 = bw2 - 100000LL - q2;
        long long su2 = ((100000LL + q2) * 1000000LL) / 352800LL;
        long long gotRi2 = (long long)s->timing.read_index;
        long long gotSu2 = (long long)s->timing.sink_usec;
        if (popped != 1000000 || gotRi1 != ri1 || gotSu1 != su1 || gotRi2 != ri2 || gotSu2 != su2) {
            fprintf(stderr, "FAIL: vsink: read_index and sink_usec include the virtual sink (drained ring: read_index %lld want %lld, sink_usec %lld want %lld; 100000 B in the ring: read_index %lld want %lld, sink_usec %lld want %lld; popped %zu)\n",
                    gotRi1, ri1, gotSu1, su1, gotRi2, ri2, gotSu2, su2, popped);
            failures++;
        } else {
            printf("ok: vsink: read_index and sink_usec include the virtual sink\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* S16LE input counts in output (ring) bytes (MUST-FIX b): 176400 input
     * bytes are 1000 ms and fill a 1000 ms sink; read_index lags in input
     * bytes. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_S16LE, 1000, 1);
        size_t w0 = pa_stream_writable_size(s);
        _test_vsink_write_n(s, 176400);
        size_t w1 = pa_stream_writable_size(s);
        size_t popped = _test_vsink_pop(352800);
        _test_vsink_update_timing(s);
        long long wantRi = (long long)s->bytes_written - 0 - 176400LL;
        long long gotRi = (long long)s->timing.read_index;
        if (w0 != 176400 || w1 != 0 || popped != 352800 || gotRi != wantRi) {
            fprintf(stderr, "FAIL: vsink: S16 input fills the virtual sink in output bytes (empty sink writable %zu want 176400; after 176400 input bytes %zu want 0; ring bytes popped %zu want 352800; read_index %lld want %lld)\n",
                    w0, w1, popped, gotRi, wantRi);
            failures++;
        } else {
            printf("ok: vsink: S16 input fills the virtual sink in output bytes\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* Guard: a large T never lets writable_size exceed the real free space
     * minus the reserve. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 20000, 1);
        _test_vsink_write_n(s, 3000000);
        size_t wl = pa_stream_writable_size(s);
        size_t wantL = (size_t)RING_CAPACITY - 3000000 - _TEST_WRITE_MARGIN;
        if (wl != wantL) {
            fprintf(stderr, "FAIL: vsink: writable_size never exceeds the real free space minus the reserve (read %zu want %zu)\n", wl, wantL);
            failures++;
        } else {
            printf("ok: vsink: writable_size never exceeds the real free space minus the reserve\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* Guard: T 0 is the 84-17 contract, whatever was written. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 0, 1);
        _test_vsink_write_n(s, 100000);
        size_t w0 = pa_stream_writable_size(s);
        size_t want0 = (size_t)RING_CAPACITY - 100000 - _TEST_WRITE_MARGIN;
        if (w0 != want0) {
            fprintf(stderr, "FAIL: vsink: T 0 keeps the 84-17 writable contract (read %zu want %zu)\n", w0, want0);
            failures++;
        } else {
            printf("ok: vsink: T 0 keeps the 84-17 writable contract\n");
        }
        _test_vsink_end(s, savedFmt);
    }

    /* The default T applies when the env is unset: the reading with the env
     * unset equals the reading with the env set to the compiled default, and
     * with a default above 0 both are 0 after the default's worth of audio
     * (with the rollback default 0 both are the 84-17 reading). */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        int defMs = _test_vsink_default_ms();
        long fillMs = defMs > 1000 ? (long)defMs : 1000L;
        size_t nb = (size_t)fillMs * 352800 / 1000;
        size_t wr[2] = { 0, 0 };
        for (int c = 0; c < 2; c++) {
            _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, c == 0 ? -1 : (defMs < 0 ? 0 : (long)defMs), 1);
            _test_vsink_write_n(s, nb);
            wr[c] = pa_stream_writable_size(s);
            _test_vsink_end(s, savedFmt);
        }
        if (defMs < 0) {
            fprintf(stderr, "FAIL: vsink: default T applies when the env is unset (default_ms=%d: the compiled default is not readable)\n", defMs);
            failures++;
        } else if (wr[0] != wr[1] || (defMs > 0 && wr[0] != 0)) {
            fprintf(stderr, "FAIL: vsink: default T applies when the env is unset (default_ms=%d, env unset reads %zu, env explicit reads %zu, want equal and 0 for a default above 0)\n", defMs, wr[0], wr[1]);
            failures++;
        } else {
            printf("ok: vsink: default T applies when the env is unset (default_ms=%d)\n", defMs);
        }
    }

    /* Underflow follows the virtual sink: with a client attached and its
     * chunk drained (ring empty), no underflow_cb while the sink holds data
     * and the clock is frozen; once the clock passes T exactly one. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 1000, 0);
        static const char vreq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int vfd = _test_connect_loopback(port);
        int vattach = (vfd >= 0
                       && write(vfd, vreq, sizeof(vreq) - 1) >= 0
                       && _test_read_header(vfd, 3000) == 0);
        if (!vattach) {
            fprintf(stderr, "FAIL: vsink: no underflow_cb while the virtual sink holds data (client could not attach)\n");
            fprintf(stderr, "FAIL: vsink: underflow_cb fires once when the virtual sink and the ring are empty (client could not attach)\n");
            failures += 2;
        } else {
            float vchunk[4] = { 0.1f, -0.1f, 0.1f, -0.1f };
            pa_stream_write(s, vchunk, sizeof(vchunk), NULL, 0, 0);
            unsigned char vgot[16];
            int gotv = (_test_read_bytes(vfd, vgot, sizeof(vgot), 2000) == 0);
            atomic_store(&_test_vsink_uf, 0);
            pa_stream_set_underflow_callback(s, _test_vsink_uf_cb, NULL);
            usleep(250000);
            int early = atomic_load(&_test_vsink_uf);
            if (!gotv || early != 0) {
                fprintf(stderr, "FAIL: vsink: no underflow_cb while the virtual sink holds data (chunk drained=%d, underflow_cb calls in 250 ms with the clock frozen: %d want 0)\n", gotv, early);
                failures++;
            } else {
                printf("ok: vsink: no underflow_cb while the virtual sink holds data\n");
            }
            _test_vsink_clock_advance_ms(2000);
            for (int i = 0; i < 100 && atomic_load(&_test_vsink_uf) == early; i++) {
                usleep(20000);
            }
            usleep(250000);
            int late = atomic_load(&_test_vsink_uf);
            if (early != 0 || late != 1) {
                fprintf(stderr, "FAIL: vsink: underflow_cb fires once when the virtual sink and the ring are empty (calls before the clock passed T: %d want 0; total after: %d want 1)\n", early, late);
                failures++;
            } else {
                printf("ok: vsink: underflow_cb fires once when the virtual sink and the ring are empty\n");
            }
            pa_stream_set_underflow_callback(s, NULL, NULL);
            close(vfd);
        }
        _test_vsink_end(s, savedFmt);
    }

    /* CR-1 hammer with the virtual sink on: the push/flush hammer races the
     * HTTP thread's underflow decision (which now also reads the sink under
     * the ring lock). Edges the hammer's own flushes legitimately open are
     * not counted; afterwards one chunk is written and drained: no
     * underflow_cb while the clock is frozen, exactly one once it passes T. */
    {
        pa_sample_format_t savedFmt = s->sample_spec.format;
        _test_vsink_begin(s, PA_SAMPLE_FLOAT32LE, 1000, 0);
        static const char jreq[] = "GET /stream HTTP/1.0\r\n\r\n";
        int jfd = _test_connect_loopback(port);
        int jattach = (jfd >= 0
                       && write(jfd, jreq, sizeof(jreq) - 1) >= 0
                       && _test_read_header(jfd, 3000) == 0);
        pthread_t jth = 0;
        test_hammer_ctx_t jctx;
        jctx.stream = s;
        jctx.done = 0;
        if (!jattach || pthread_create(&jth, NULL, _test_hammer_thread_fn, &jctx) != 0) {
            fprintf(stderr, "FAIL: vsink: underrun edge survives push/flush hammering with the virtual sink on (could not attach a client or start the hammer thread)\n");
            failures++;
            if (jfd >= 0) {
                close(jfd);
            }
        } else {
            unsigned char jdiscard[4096];
            while (!jctx.done) {
                if (jfd < 0) {
                    jfd = _test_connect_loopback(port);
                    if (jfd >= 0
                        && (write(jfd, jreq, sizeof(jreq) - 1) < 0
                            || _test_read_header(jfd, 500) != 0)) {
                        close(jfd);
                        jfd = -1;
                    }
                } else {
                    struct pollfd jp; jp.fd = jfd; jp.events = POLLIN;
                    if (poll(&jp, 1, 20) > 0) {
                        ssize_t n = read(jfd, jdiscard, sizeof(jdiscard));
                        if (n <= 0) {
                            close(jfd);
                            jfd = -1;
                        }
                    }
                }
            }
            pthread_join(jth, NULL);
            if (jfd >= 0) {
                close(jfd);
                jfd = -1;
            }
            jfd = _test_connect_loopback(port);
            int jattach2 = (jfd >= 0
                            && write(jfd, jreq, sizeof(jreq) - 1) >= 0
                            && _test_read_header(jfd, 3000) == 0);
            if (!jattach2) {
                fprintf(stderr, "FAIL: vsink: underrun edge survives push/flush hammering with the virtual sink on (could not re-attach for the final cycle)\n");
                failures++;
            } else {
                atomic_store(&_test_vsink_uf, 0);
                pa_stream_set_underflow_callback(s, _test_vsink_uf_cb, NULL);
                usleep(200000);   /* any legitimate edge of the emptied sink fires here */
                float jchunk[4] = { 0.2f, -0.2f, 0.2f, -0.2f };
                pa_stream_write(s, jchunk, sizeof(jchunk), NULL, 0, 0);
                unsigned char jgot[16];
                int gotj = (_test_read_bytes(jfd, jgot, sizeof(jgot), 2000) == 0);
                int base = atomic_load(&_test_vsink_uf);
                usleep(250000);
                int mid = atomic_load(&_test_vsink_uf);
                _test_vsink_clock_advance_ms(2000);
                for (int i = 0; i < 100 && atomic_load(&_test_vsink_uf) == mid; i++) {
                    usleep(20000);
                }
                usleep(250000);
                int late = atomic_load(&_test_vsink_uf);
                if (!gotj || mid != base || late != base + 1) {
                    fprintf(stderr, "FAIL: vsink: underrun edge survives push/flush hammering with the virtual sink on (final chunk drained=%d, calls: base %d, before the clock passed T %d, after %d; want mid == base and after == base + 1)\n",
                            gotj, base, mid, late);
                    failures++;
                } else {
                    printf("ok: vsink: underrun edge survives push/flush hammering with the virtual sink on\n");
                }
                pa_stream_set_underflow_callback(s, NULL, NULL);
            }
            if (jfd >= 0) {
                close(jfd);
            }
        }
        _test_vsink_end(s, savedFmt);
    }

    /* 84-22 (F-20-WRITER, todo fake-libpulse-writer-bricht-nach-langer-pause-ab):
     * the HTTP writer used to give up on a client that made no progress for
     * 2 s and report it departed (`client-close: write error/disconnect`).
     * A player that pauses reading for ~15 s (network hiccup, sync group, CPU;
     * live: a SIGSTOPped squeezelite, 12.05 / 12.58 s after the stop in the two
     * HEAD archives) lost its stream that way and LMS stopped ~27 s after the
     * resume. The writer is departed only on a real hangup/error; a flush and a
     * takeover end a stalled write within a tick; a client that never reads is
     * bounded by an orphan limit that counts no-progress time. */
    {
        _test_wr_reset();
        int w1_fd = _test_wr_attach(port);
        int w1_stalled = 0, w1_conn = 0, w1_gen_same = 0;
        long w1_bad = -1;
        int64_t w1_dep0 = g_departed_client_generation;
        if (w1_fd >= 0) {
            _test_wr_push(s, 0, _TEST_WR_SAMPLES);
            w1_stalled = _test_wr_wait_stalled();
            usleep(4000000);   /* the reader is idle for 4 s: above the old 2 s bound */
            w1_conn = _test_wr_connected();
            w1_gen_same = (g_departed_client_generation == w1_dep0);
            w1_bad = _test_wr_read_ramp(w1_fd, 0, _TEST_WR_SAMPLES, 15000);
        }
        if (w1_fd < 0 || !w1_stalled || w1_conn != 1 || !w1_gen_same || w1_bad != 0) {
            fprintf(stderr, "FAIL: writer: a client that stops reading for 4 s stays attached and gets contiguous bytes: attached=%d writer_stalled=%d client_connected_after_4s=%d (want 1) departed_generation_unchanged=%d wrong_samples=%ld (want 0; -1 = the bytes never arrived)\n",
                    w1_fd >= 0, w1_stalled, w1_conn, w1_gen_same, w1_bad);
            failures++;
        } else {
            printf("ok: writer: a client that stops reading for 4 s stays attached and gets contiguous bytes (%zu samples, 0 wrong)\n", _TEST_WR_SAMPLES);
        }
        if (w1_fd >= 0) {
            close(w1_fd);
        }
        _test_wr_reset();
    }

    {
        _test_wr_reset();
        int w2_fd = _test_wr_attach(port);
        int w2_stalled = 0, w2_closed = 0;
        long w2_ms = -1;
        char w2_txt[8192];
        w2_txt[0] = '\0';
        if (w2_fd >= 0) {
            _test_wr_push(s, 0, _TEST_WR_SAMPLES);
            w2_stalled = _test_wr_wait_stalled();
            _test_trace_t w2_tr;
            int w2_cap = (_test_trace_begin(&w2_tr) == 0);
            long w2_t0 = _test_wr_now_ms();
            pa_operation *w2_op = pa_stream_flush(s, NULL, NULL);   /* the skip: unarmed -> g_flush_disconnect */
            if (w2_op) {
                pa_operation_unref(w2_op);
            }
            while (_test_wr_connected() && _test_wr_now_ms() - w2_t0 < 3000) {
                usleep(2000);
            }
            w2_ms = _test_wr_now_ms() - w2_t0;
            w2_closed = !_test_wr_connected();
            if (w2_cap) {
                _test_trace_end(&w2_tr, w2_txt, sizeof(w2_txt));
            }
        }
        int w2_flush_lit = (strstr(w2_txt, "flush-disconnect: closed active HTTP client") != NULL);
        int w2_err_lit = (strstr(w2_txt, "client-close: write error/disconnect") != NULL);
        if (w2_fd < 0 || !w2_stalled || !w2_closed || w2_ms > 60 || !w2_flush_lit || w2_err_lit) {
            fprintf(stderr, "FAIL: writer: a flush during a stalled write returns within one tick and closes via the flush path: attached=%d writer_stalled=%d closed=%d after_ms=%ld (want <= 60) flush_literal=%d (want 1) write_error_literal=%d (want 0)\n",
                    w2_fd >= 0, w2_stalled, w2_closed, w2_ms, w2_flush_lit, w2_err_lit);
            failures++;
        } else {
            printf("ok: writer: a flush during a stalled write returns within one tick and closes via the flush path (closed %ld ms after the flush)\n", w2_ms);
        }
        if (w2_fd >= 0) {
            close(w2_fd);
        }
        _test_wr_reset();
    }

    {
        _test_wr_reset();
        int w3_fd = _test_wr_attach(port);
        int w3_stalled = 0, w3_hdr = 0;
        long w3_ms = -1;
        int w3_fd2 = -1;
        char w3_txt[8192];
        w3_txt[0] = '\0';
        if (w3_fd >= 0) {
            _test_wr_push(s, 0, _TEST_WR_SAMPLES);
            w3_stalled = _test_wr_wait_stalled();
            _test_trace_t w3_tr;
            int w3_cap = (_test_trace_begin(&w3_tr) == 0);
            w3_fd2 = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in w3_sa;
            memset(&w3_sa, 0, sizeof(w3_sa));
            w3_sa.sin_family = AF_INET;
            w3_sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            w3_sa.sin_port = htons((uint16_t)port);
            static const char w3_req[] = "GET /stream HTTP/1.0\r\n\r\n";
            long w3_t0 = _test_wr_now_ms();
            if (w3_fd2 >= 0 && connect(w3_fd2, (struct sockaddr *)&w3_sa, sizeof(w3_sa)) == 0
                && write(w3_fd2, w3_req, sizeof(w3_req) - 1) > 0) {
                w3_hdr = (_test_read_header(w3_fd2, 3000) == 0);
            }
            w3_ms = _test_wr_now_ms() - w3_t0;
            if (w3_cap) {
                _test_trace_end(&w3_tr, w3_txt, sizeof(w3_txt));
            }
        }
        int w3_take_lit = (strstr(w3_txt, "client-close: superseded by new connection (takeover)") != NULL);
        int w3_err_lit = (strstr(w3_txt, "client-close: write error/disconnect") != NULL);
        if (w3_fd < 0 || !w3_stalled || !w3_hdr || w3_ms > 500 || !w3_take_lit || w3_err_lit) {
            fprintf(stderr, "FAIL: writer: a takeover during a stalled write is served: attached=%d writer_stalled=%d second_client_header=%d after_ms=%ld (want <= 500) takeover_literal=%d (want 1) write_error_literal=%d (want 0)\n",
                    w3_fd >= 0, w3_stalled, w3_hdr, w3_ms, w3_take_lit, w3_err_lit);
            failures++;
        } else {
            printf("ok: writer: a takeover during a stalled write is served (second client got its header after %ld ms)\n", w3_ms);
        }
        if (w3_fd2 >= 0) {
            close(w3_fd2);
        }
        if (w3_fd >= 0) {
            close(w3_fd);
        }
        _test_wr_reset();
    }

    {
        _test_wr_reset();
        setenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS", "500", 1);
        int w4_fd = _test_wr_attach(port);
        int w4_closed = 0;
        long w4_ms = -1;
        char w4_txt[8192];
        w4_txt[0] = '\0';
        int64_t w4_dep = NO_CLIENT_GENERATION;
        if (w4_fd >= 0) {
            _test_trace_t w4_tr;
            int w4_cap = (_test_trace_begin(&w4_tr) == 0);
            long w4_t0 = _test_wr_now_ms();
            _test_wr_push(s, 0, _TEST_WR_SAMPLES);   /* the client never reads: the socket fills, then no progress */
            while (_test_wr_connected() && _test_wr_now_ms() - w4_t0 < 4000) {
                usleep(10000);
            }
            w4_ms = _test_wr_now_ms() - w4_t0;
            w4_closed = !_test_wr_connected();
            w4_dep = g_departed_client_generation;
            if (w4_cap) {
                _test_trace_end(&w4_tr, w4_txt, sizeof(w4_txt));
            }
        }
        unsetenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS");
        /* The close time since the push is NOT the bound: the HTTP thread drains the
         * ring at most HTTP_DRAIN_BUDGET (~35 KB) per 50 ms tick, so the ~900 KB the
         * socket takes before it fills arrive over ~1.3 s (measured: closed ~1410 ms
         * after the push, every run) and only then does no progress begin. The bound
         * is read from the writer's own literal -- `no progress for <ms> ms` is the
         * no-progress interval it measured -- and must lie in 500..1500. */
        const char *w4_lit = strstr(w4_txt, "client-close: write orphan (no progress for ");
        long w4_idle = w4_lit ? strtol(w4_lit + strlen("client-close: write orphan (no progress for "), NULL, 10) : -1;
        if (w4_fd < 0 || !w4_closed || w4_ms < 500 || w4_ms > 4000 || !w4_lit || w4_idle < 500 || w4_idle > 1500 || w4_dep == NO_CLIENT_GENERATION) {
            fprintf(stderr, "FAIL: writer: the orphan bound closes a never-reading client after the configured time: attached=%d closed=%d after_ms=%ld (want 500..4000) orphan_literal=%d no_progress_ms=%ld (want 500..1500) departed_generation_set=%d (want 1)\n",
                    w4_fd >= 0, w4_closed, w4_ms, w4_lit != NULL, w4_idle, w4_dep != NO_CLIENT_GENERATION);
            failures++;
        } else {
            printf("ok: writer: the orphan bound closes a never-reading client after the configured time (no progress for %ld ms, bound 500 ms; closed %ld ms after the push)\n", w4_idle, w4_ms);
        }
        if (w4_fd >= 0) {
            close(w4_fd);
        }
        _test_wr_reset();
    }

    {
        /* The shipped orphan bound (WRITER_UPPER_BOUND_DECISION, checkpoint 2a, the
         * user's answer "180 s"): with the env unset or empty the writer's bound is
         * 180000 ms, and the env override still wins. Read through the function the
         * write loop itself calls, so the define cannot drift from the behaviour. */
        unsetenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS");
        long w6_default = _write_orphan_ms();
        setenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS", "", 1);
        long w6_empty = _write_orphan_ms();
        setenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS", "500", 1);
        long w6_env = _write_orphan_ms();
        unsetenv("SPOTON_FAKEPULSE_WRITE_ORPHAN_MS");
        if (w6_default != 180000 || w6_empty != 180000 || w6_env != 500) {
            fprintf(stderr, "FAIL: writer: the orphan bound defaults to 180000 ms when the env is unset: unset=%ld (want 180000) empty=%ld (want 180000) env500=%ld (want 500)\n",
                    w6_default, w6_empty, w6_env);
            failures++;
        } else {
            printf("ok: writer: the orphan bound defaults to 180000 ms when the env is unset (unset %ld, empty %ld, env override %ld)\n", w6_default, w6_empty, w6_env);
        }
    }

    {
        /* a connection that never completes its request head must not occupy
         * the pending slot for the whole stall: the stall bound used to end the
         * write every 2 s and let the main loop expire it; with the 2 s bound
         * gone the write loop expires it itself (HTTP_REQUEST_TIMEOUT_MS). */
        _test_wr_reset();
        int w5_fd = _test_wr_attach(port);
        int w5_stalled = 0, w5_eof = 0, w5_conn = 0;
        long w5_ms = -1;
        if (w5_fd >= 0) {
            _test_wr_push(s, 0, _TEST_WR_SAMPLES);
            w5_stalled = _test_wr_wait_stalled();
            int w5_pf = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in w5_sa;
            memset(&w5_sa, 0, sizeof(w5_sa));
            w5_sa.sin_family = AF_INET;
            w5_sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            w5_sa.sin_port = htons((uint16_t)port);
            long w5_t0 = _test_wr_now_ms();
            if (w5_pf >= 0 && connect(w5_pf, (struct sockaddr *)&w5_sa, sizeof(w5_sa)) == 0
                && write(w5_pf, "GET /stre", 9) == 9) {
                while (_test_wr_now_ms() - w5_t0 < 4500) {
                    struct pollfd w5_p;
                    w5_p.fd = w5_pf;
                    w5_p.events = POLLIN;
                    if (poll(&w5_p, 1, 50) > 0) {
                        char w5_b[16];
                        ssize_t w5_n = read(w5_pf, w5_b, sizeof(w5_b));
                        if (w5_n <= 0) {
                            w5_eof = 1;
                            break;
                        }
                    }
                }
            }
            w5_ms = _test_wr_now_ms() - w5_t0;
            w5_conn = _test_wr_connected();
            if (w5_pf >= 0) {
                close(w5_pf);
            }
        }
        if (w5_fd < 0 || !w5_stalled || !w5_eof || w5_ms > 3500 || w5_conn != 1) {
            fprintf(stderr, "FAIL: writer: a pending connection that never completes its request head is expired while a write is stalled: attached=%d writer_stalled=%d pending_closed=%d after_ms=%ld (want <= 3500) streaming_client_still_attached=%d (want 1)\n",
                    w5_fd >= 0, w5_stalled, w5_eof, w5_ms, w5_conn);
            failures++;
        } else {
            printf("ok: writer: a pending connection that never completes its request head is expired while a write is stalled (closed after %ld ms, the stalled client stayed attached)\n", w5_ms);
        }
        if (w5_fd >= 0) {
            close(w5_fd);
        }
        _test_wr_reset();
    }

    /* 79-07 (84 WR-01): stream teardown must wait for a writer blocked on a
     * full ring. The writer is woken by the teardown, a test-only delay keeps
     * it away from the stream for a while (as a descheduled thread would be),
     * and at unref's return the writer must already have left
     * pa_stream_write -- otherwise the stream is freed under it. */
    {
        _test_ring_reset();
        unsetenv("SPOTON_FAKEPULSE_WRITE_WAIT_MS");
        pa_sample_spec wr_ss;
        wr_ss.format = PA_SAMPLE_S32LE;
        wr_ss.rate = 44100;
        wr_ss.channels = 2;
        pa_stream *wr_s = pa_stream_new(NULL, "wr01", &wr_ss, NULL);
        pa_stream_connect_playback(wr_s, NULL, NULL, 0, NULL, NULL);
        int32_t wr_seq = 0;
        int32_t *wr_fill = _test_seq_buf((size_t)RING_CAPACITY, &wr_seq);
        int32_t *wr_chunk = _test_seq_buf(4096, &wr_seq);
        if (!wr_s || !wr_fill || !wr_chunk) {
            fprintf(stderr, "FAIL: pa_stream_unref returns only after a blocked writer left pa_stream_write: setup (stream/malloc)\n");
            failures++;
        } else {
            pa_stream_write(wr_s, wr_fill, (size_t)RING_CAPACITY, NULL, 0, 0);
            _test_writer_t wr_w = { .s = wr_s, .data = wr_chunk, .nbytes = 4096 };
            atomic_init(&wr_w.done, 0);
            atomic_store(&g_test_writer_left, 0);
            atomic_store(&g_test_writer_wake_delay_ms, 400);
            pthread_t wr_th;
            pthread_create(&wr_th, NULL, _test_writer_thread, &wr_w);
            usleep(300000);
            int wr_blocked = !atomic_load(&wr_w.done);
            pa_stream_unref(wr_s);          /* wr_s must not be touched after this */
            int wr_left = atomic_load(&g_test_writer_left);
            pthread_join(wr_th, NULL);
            atomic_store(&g_test_writer_wake_delay_ms, 0);
            if (!wr_blocked || !wr_left) {
                fprintf(stderr, "FAIL: pa_stream_unref returns only after a blocked writer left pa_stream_write: writer_blocked_before_unref=%d writer_left_at_unref_return=%d (want 1 and 1)\n",
                        wr_blocked, wr_left);
                failures++;
            } else {
                printf("ok: pa_stream_unref returns only after a blocked writer left pa_stream_write (writer was blocked, had left when unref returned)\n");
            }
        }
        free(wr_fill);
        free(wr_chunk);
        g_active_stream = s;
        pthread_mutex_lock(&g_ring.lock);
        _vsink_sync_locked(_vsink_ms());
        _vsink_set_running_locked(!s->corked);
        pthread_mutex_unlock(&g_ring.lock);
        _test_ring_reset();
    }

    /* 79-07 (84 WR-01, secondary): unref of a stream that is not the active
     * one must not bump flush_epoch -- that would make an in-flight write on
     * the active stream abandon its remaining batches. */
    {
        pa_sample_spec ep_ss;
        ep_ss.format = PA_SAMPLE_S32LE;
        ep_ss.rate = 44100;
        ep_ss.channels = 2;
        pa_stream *ep_s = pa_stream_new(NULL, "wr01b", &ep_ss, NULL);
        pthread_mutex_lock(&g_ring.lock);
        uint64_t ep0 = g_ring.flush_epoch;
        pthread_mutex_unlock(&g_ring.lock);
        pa_stream_unref(ep_s);
        pthread_mutex_lock(&g_ring.lock);
        uint64_t ep1 = g_ring.flush_epoch;
        pthread_mutex_unlock(&g_ring.lock);
        if (!ep_s || ep0 != ep1) {
            fprintf(stderr, "FAIL: unref of a non-active stream leaves flush_epoch unchanged: before=%llu after=%llu\n",
                    (unsigned long long)ep0, (unsigned long long)ep1);
            failures++;
        } else {
            printf("ok: unref of a non-active stream leaves flush_epoch unchanged (epoch %llu)\n", (unsigned long long)ep1);
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
