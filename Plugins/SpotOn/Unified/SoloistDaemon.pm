package Plugins::SpotOn::Unified::SoloistDaemon;

# Phase 73 Plan 01 (D-01/D-02/D-05, RESEARCH Pattern 5): per-player lifecycle
# class for the persistent Soloist daemon. A separate class from
# Unified::Daemon (librespot) rather than an extension of it -- the
# differences are structural: no credentials.json gate, two announced ports
# (WS control + HTTP audio) instead of one, LD_LIBRARY_PATH env for
# fake-libpulse, per-player data-dir (D-01), and the spak-key crosses via
# argv (unchanged ACCEPTED RISK WR-01, Phase 72). The %helperInstances
# registry, CRASH_BACKOFF_*, stagger-start, and deviceNameForClient in
# DaemonManager work unmodified against this class (Pattern 5).

use strict;
use warnings;

use base qw(Slim::Utils::Accessor);

use File::Spec::Functions qw(catdir catfile);
use Fcntl qw(S_ISDIR S_ISREG);
use File::Temp qw(tempfile);
use Scalar::Util qw(weaken);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::Select;
use Time::HiRes;

# M12-style async port-announcement poll -- 0.1s interval, 100 attempts (10s
# cap). Mirrors Unified::Daemon's PORT_POLL_INTERVAL/PORT_POLL_MAX_ATTEMPTS.
use constant PORT_POLL_INTERVAL     => 0.1;
use constant PORT_POLL_MAX_ATTEMPTS => 100;

# Phase 83.3 plan 03 (D-06): the renewal smoke test starts a throwaway
# instance of a freshly-downloaded candidate and watches for the
# "client expires in N days" banner on its stdout. 20ms/500 attempts = a
# 10s cap, matching the port-poll budget above; the event-driven pipe read
# (see smokeTest below) is expected to resolve almost every run long before
# this fallback poll's countdown matters.
use constant SMOKE_POLL_INTERVAL     => 0.02;
use constant SMOKE_POLL_MAX_ATTEMPTS => 500;
use constant SMOKE_DEVICE_NAME       => 'SpotOn smoke test';

# 74b-04 (T-74b-13, T-74b-15): bounds for the per-player <id>-soloist.log.
# The log is our own redirect of the daemon's stdout+stderr; with diagnostics
# on the daemon is also started verbose, and an unbounded log reached 2.3 GB.
#  - at daemon start a log above LOG_ROTATE_AT_START_BYTES (10 MB) is rotated
#    whole to .1 (one previous generation stays for after-the-fact debugging);
#    a log above LOG_RUNTIME_CAP_BYTES (such as a 2.3 GB log that predates this
#    code) keeps only its last LOG_KEEP_TAIL_BYTES (5 MB) in .1.
#  - while the daemon runs, LOG_CAP_INTERVAL (30 s) checks the size; above
#    LOG_RUNTIME_CAP_BYTES (50 MB) the last 5 MB move to .1 and the live file
#    restarts empty. 50 MB holds hours of verbose playback, so a measurement
#    window read by tools/uat/extract-run.pl stays inside the live file plus
#    .1. Per player that bounds the log at about 100 MB (live file up to 50 MB
#    plus one .1 of at most 50 MB).
# Not configurable: diagnostics are an expert switch, the cap is a safety
# bound and not a tuning knob.
use constant LOG_ROTATE_AT_START_BYTES => 10 * 1024 * 1024;
use constant LOG_RUNTIME_CAP_BYTES     => 50 * 1024 * 1024;
use constant LOG_KEEP_TAIL_BYTES       => 5 * 1024 * 1024;
use constant LOG_CAP_INTERVAL          => 30;

# GH #208 (quick 261111-j58): size limit of the Soloist audio cache per player,
# in MB. The Soloist counterpart of Unified::Daemon's AUDIO_CACHE_LIMIT_BYTES
# (74b-04, librespot only). The value goes to the binary as '-z' (MB, see
# _spawnArgs) and, from the cache prune in start(), as the limit the existing
# cache is pruned to before every spawn.
use constant SOLOIST_CACHE_LIMIT_MB    => 1024;

# 260914-qn1 (Signature C): originally the same size/shape as
# Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S (Control.pm:140), a
# deliberately SEPARATE constant (not imported/shared) because it bounded
# a different wait -- "Control instance exists" here, "WS handshake+login
# complete" there.
#
# Phase 82 Plan 44 (D-12, Runde 44): both are now delegating subs reading
# the SAME shared budget (Plugins::SpotOn::Unified::DeferBudget::
# TOTAL_DEFER_BUDGET_S, 20s) -- staggering two independent 25s TTLs across
# levels could add up to 50s (or 75s with a third level); D-12 binds all
# levels to one 20s budget from the original request instead. Delegating
# sub (not a plain re-export), empty prototype `()`, so existing bareword
# call sites (e.g. this file's own "... . PENDING_TRACK_TTL_S . ...")
# keep working unchanged.
sub PENDING_TRACK_TTL_S () {
    require Plugins::SpotOn::Unified::DeferBudget;
    return Plugins::SpotOn::Unified::DeferBudget::TOTAL_DEFER_BUDGET_S();
}

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	name
	_proc
	_startTimes
	_wsPort
	_streamPort
	_ws
	_control
	_stderrFile
	_stderrStartOffset
	_spawnTime
	_wsPortPollAttempts
	_httpPortTmpfile
	_httpPortPollAttempts
	_accountId
	_connectEnabled
	_passthrough
	_lastHealthSession
	_healthCheckCount
	_pendingTrackRequest
	_exitStatus
	_exitWatcher
	_stoppedDeliberately
	_healthProbeSentAt
	_healthUnhealthySince
	_healthLmsTime
	_healthLmsTimeAt
	_healthStopReason
) );
# 84.1-08 (WR-05, D-05): the Song object the D-05 rising-LMS-time sample was
# last taken against -- weak (a freed Song must never keep the deferral
# guard comparing against it), keyed per-incident by object identity, never
# a time window (Pitfall 4).
__PACKAGE__->mk_accessor( weak => qw( _healthLmsSong ) );
# NOTE: _accountId is left undef on purpose -- SoloistDaemon has no
# credentials.json/account concept (spak-key is server-wide), which gates
# DaemonManager's librespot-only audio-key cohort block off naturally
# (_streamAlivePoll checks `$helper->_accountId` before running it).
# NOTE: _lastHealthSession/_healthCheckCount exist for interface parity with
# Unified::Daemon (DaemonManager's health-poll code reads them generically)
# but fake-libpulse has no /health endpoint -- _streamAlivePoll gates that
# HTTP probe on `$helper->isa('Plugins::SpotOn::Unified::Daemon')`.
# NOTE (84.1 plan 03, D-04/D-05; 84.1-08 WR-05 adds _healthLmsSong): the six
# _health* accessors back DaemonManager's _soloistHealthTick --
# _healthProbeSentAt/_healthStopReason for the login/answer-deadline
# detector, _healthUnhealthySince/_healthLmsTime/_healthLmsTimeAt/
# _healthLmsSong for the D-05 rising-LMS-time deferral guard (the last one
# keyed per-incident and per-song, weak, so a new Song is always a first
# sample). Per-instance (not module-level like %soloistHealth in
# DaemonManager.pm) because the helper OBJECT survives a crash-restart
# (startHelper's dead-helper branch calls ->start on the SAME instance) --
# only a brand-new construction after a full stopHelper() loses them, which
# is exactly when a fresh probe/deadline cycle should start anyway.

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

# Phase 83.3 plan 15 (G-83.3-3): undef = not yet probed; 0/1 after the first
# `eval { require EV; 1 }` in _watchExit below. Probed at most once per
# process -- EV either loads from LMS's bundled CPAN tree or it doesn't, and
# that answer never changes mid-run.
my $haveEV;


# 84-07 (SEAM-6.2): which backend this daemon belongs to. DaemonManager's
# `isa('...SoloistDaemon')` sites become `backendName eq 'soloist'` (84-08).
sub backendName { return 'soloist'; }

sub new {
	my ($class, $id) = @_;

	my $self = $class->SUPER::new();

	$self->mac($id);
	$id =~ s/://g;
	$self->id($id);
	$self->_startTimes([]);
	$self->_healthCheckCount(0);
	$self->_passthrough(0);    # D-04: soloist HTTP mode is S16LE-PCM-only
	$self->start();

	return $self;
}

# _spawnArgs($binaryPath, $key, $name, $dataDir, $cacheDir, $initialVolume, $verbose)
# PURE argv builder (testable without a live client/daemon context, t/28).
# -w 127.0.0.1:0 is a hard security requirement (T-73-01/RESEARCH V4) -- the
# WS control API has zero auth/TLS/origin checks; never a wildcard bind.
#
# $verbose (optional, 7th arg, 83.2-01/D-03): when true, '-v' is appended as
# the LAST element -- soloist's only CLI addition since 1.3.7.521
# (soloist-releases/changelogs/CHANGELOG-1.3.8.68.md: "Use the --verbose
# option to show all logs for troubleshooting"). This is a pure log-level
# switch, not a new output channel or format (RESEARCH Sec 1) -- it does not
# change any playback/control behavior, so it stays within the CONTEXT
# Phase-Boundary allowance for "an intervention that makes a measurement
# possible in the first place" (D-03). The fail-closed version pin
# (Soloist.pm:44-50) guarantees the running binary is >= 1.3.8, so an older
# binary lacking -v can never be spawned with it. Callers pass
# diagnosticMode as $verbose -- the same pref that already routes stdout via
# the existing restart hook (Plugin.pm:235-248, 'diagnosticMode' setChange)
# for librespot/RUST_LOG; that hook already restarts every Unified daemon on
# change, so no new restart wiring is needed here.
#
# GH #208: '-z <MB>' (SOLOIST_CACHE_LIMIT_MB, 1024) caps the Soloist audio cache.
# soloist-1.3.8.68 --help prints "-z, --cache-size <MB>  Max cache size in MB
# (min 100, 0 = no limit, default: no limit)"; the flag and its bound message
# ("--cache-size must be 0 (no limit) or >= 100") are present in all three
# pinned builds (x86_64 1.3.8.68, aarch64 and armhf 1.3.8.69). Without '-z' the
# cache is unlimited, which filled the disk (11 GB, 424 files on a real
# install). The fail-closed lower-bound version pin (Soloist.pm:44-50) keeps
# every spawned binary at or above a build that knows '-z'. smokeTest spawns
# with the same argv, so a later build that rejected '-z' would fail the smoke
# test and not activate (fail-closed, accepted).
sub _spawnArgs {
	my ($class, $binaryPath, $key, $name, $dataDir, $cacheDir, $initialVolume, $verbose) = @_;

	my @args = (
		$binaryPath,
		'-n', $name,
		'-k', $key,
		'-D', $dataDir,
		'-C', $cacheDir,
		'-z', SOLOIST_CACHE_LIMIT_MB,
		'-w', '127.0.0.1:0',
		'-i', $initialVolume,
	);
	push @args, '-v' if $verbose;

	return @args;
}

# GH #208 (quick 261111-j58): the time budget of the cache prune in start(), in
# seconds, for the DELETION phase only. Set by the orchestrator on 2026-11-11
# and NOT measured; neither is the unlink speed of a Pi / SD card known.
#  - The scan before it (readdir and lstat over up to 256 dirs and about 1600
#    files on the largest local player) is NOT budgeted: it must be complete,
#    or the oldest-first order would be wrong. Its duration is NOT measured
#    either.
#  - The largest local player needs about 1400 unlinks to get under the limit.
#  - Every start over the limit deletes at least one file, whatever the budget.
#    The rest follows at the next start; -z bounds the binary meanwhile.
use constant SOLOIST_PRUNE_BUDGET_S => 2;

# _pruneSoloistCache($invocant, $cacheDir, $limitBytes, $budgetSeconds)
# GH #208 (quick 261111-j58): delete the oldest audio cache files of one
# Soloist player (by mtime, ties by path) until their total is at or below
# $limitBytes; returns (deleted count, freed bytes, incomplete). $limitBytes
# is in MiB * 1024 * 1024, equal to or above the binary's own -z bound
# whichever MB base it uses, so the prune never fights the binary. incomplete
# is 1 when the time budget stopped the deletion with the cache still over the
# limit.
# Layout (format string "%s%.2x/%s.file" of the binary, checked on the real
# tree: 1609 of 1609 entries match): <cacheDir>/cache/<2 hex>/<40 hex>.file,
# the 2-hex dir being the first two characters of the name. ONLY such files
# count and may be deleted: the root must be a real directory, a sub dir a real
# directory with a two-character lowercase hex name, a file a regular file
# (lstat, symlinks are never followed at any level). Everything else stays,
# and the sibling data/cache (Soloist state, not audio) is never touched.
# Never dies: any error ends in the partial result.
# W2: Soloist counts files deleted from outside as "Missing" in its startup
# enumeration. At most 1 Missing was ever observed (live log and the
# spoton-messdaten archive: 370 times 0, 66 times 1); the mass case (about
# 1400 for one player) is UNTESTED until the VM-rig check.
sub _pruneSoloistCache {
	my ($invocant, $cacheDir, $limit, $budget) = @_;
	$limit  = SOLOIST_CACHE_LIMIT_MB * 1024 * 1024 unless defined $limit;
	$budget = SOLOIST_PRUNE_BUDGET_S unless defined $budget;

	my ($deleted, $freed, $incomplete) = (0, 0, 0);
	return ($deleted, $freed, $incomplete) unless defined $cacheDir && length $cacheDir;

	my $root = catdir($cacheDir, 'cache');
	eval {
		my @rst = lstat($root);
		return unless @rst && S_ISDIR($rst[2]);

		opendir(my $dh, $root) or die "opendir $root: $!";
		my @subdirs = grep { /\A[0-9a-f]{2}\z/ } readdir($dh);
		closedir($dh);

		my @files;
		my $total = 0;
		for my $sub (@subdirs) {
			my $subPath = catdir($root, $sub);
			my @st = lstat($subPath) or next;
			next unless S_ISDIR($st[2]);

			opendir(my $sdh, $subPath) or next;
			my @names = grep { /\A([0-9a-f]{2})[0-9a-f]{38}\.file\z/ && $1 eq $sub } readdir($sdh);
			closedir($sdh);

			for my $name (@names) {
				my $path = catfile($subPath, $name);
				my @fst = lstat($path) or next;
				next unless S_ISREG($fst[2]);
				push @files, [ $fst[9], $path, $fst[7] ];
				$total += $fst[7];
			}
		}

		return if $total <= $limit;

		# the clock for the deletion phase starts only now, after the scan
		my $t0 = Time::HiRes::time();
		my $over = sub { return Time::HiRes::time() - $t0 >= $budget };
		my $attempts = 0;

		for my $f (sort { $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1] } @files) {
			last if $total <= $limit;
			# the first unlink of a start is never budget-checked: guaranteed progress
			if ($attempts > 0 && $over->()) {
				$incomplete = 1;
				last;
			}
			$attempts++;
			if (unlink $f->[1]) {
				$total   -= $f->[2];
				$freed   += $f->[2];
				$deleted++;
			}
			else {
				$log->warn("SpotOn Soloist daemon: cannot prune cache file $f->[1]: $!");
			}
		}
		1;
	};
	$log->warn("SpotOn Soloist daemon: audio cache prune error: $@") if $@;

	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Soloist daemon: cache prune of $root: $deleted file(s), $freed bytes freed"
		. ($incomplete ? ", stopped by the $budget s budget, the rest follows at the next start" : '')
	) if $deleted || $incomplete;

	return ($deleted, $freed, $incomplete);
}

# 79-55 (GH #184, forum #329): piCorePlayer's init script starts LMS as root
# with --user tc and LMS drops only the effective ids, so every child is
# exec'd with AT_SECURE=1 and the loader silently removes LD_PRELOAD and
# LD_LIBRARY_PATH: the fake-libpulse shim never loads.
# _idsDiffer() -- true when the real uid/gid differ from the effective ones.
# Read on every call (never cached); also the test seam.
sub _idsDiffer {
	my ($ruid, $euid, $rgid, $egid) = @_ ? @_ : ($<, $>, 0 + $(, 0 + $));
	return 1 if $ruid != $euid;
	return 1 if $rgid != $egid;
	return 0;
}

# _useSecureExec($ruid, $euid, $rgid, $egid) -- 79-57 (I-4, 79-55-SECURITY):
# spawn through the wrapper only when the ids differ AND the effective uid is
# not 0. The wrapper sets the real uid to the effective one, so with an
# effective uid 0 it would RAISE the real uid to 0; by construction that can
# never happen. Pure (the ids are arguments); the spawn passes the current
# ones.
sub _useSecureExec {
	my ($ruid, $euid, $rgid, $egid) = @_;
	return 0 if $euid == 0;
	return _idsDiffer($ruid, $euid, $rgid, $egid) ? 1 : 0;
}

# 79-57 (N3, 79-55-SECURITY): perl reads these at startup (module search
# path, implicit -M/-I options). The wrapper perl runs with a real uid 0 on
# piCorePlayer, so they are removed for the wrapper spawn only and restored
# right after it; an equal-ids spawn keeps them (byte-identical env).
use constant SECURE_EXEC_PERL_ENV => qw(PERL5LIB PERLLIB PERL5OPT);

# The six variables that must reach Soloist through the wrapper's argv,
# because the wrapper perl itself is exec'd in secure mode and loses LD_*.
use constant SECURE_EXEC_ENV_NAMES => qw(
	LD_LIBRARY_PATH LD_PRELOAD SPOTON_SOLOIST_HTTP_PORT_FILE
	SPOTON_FAKEPULSE_DEBUG PIPEWIRE_RUNTIME_DIR PIPEWIRE_REMOTE
);

# _secureExecWrapperCode() -- the perl -e program of the wrapper (79-55).
# It is SpotOn's own process changing its own real ids and environment and
# then exec'ing the unchanged Soloist binary with unchanged arguments; the
# binary itself is never modified, patched or wrapped (Spotify terms V.11).
# Steps: (1) NAME=VALUE items up to a literal --, names from the six only;
# (2) untaint argv, values and PATH/IFS/CDPATH/ENV/BASH_ENV/TERM unchanged
# (perl enables taint by itself when the real uid is not 0 and differs from
# the effective uid); under taint PATH is set to /usr/bin:/bin, because exec
# under taint also refuses a relative or world-writable PATH element and the
# target is exec'd by absolute path anyway (79-57, IN-07); (3) real gid := effective gid, real uid := effective
# uid, never the effective ids or the group list; (4) re-read and report a
# failed change, then go on; (5) export the pairs; (6) exec in place (same
# pid), list form, no shell. The code loads no module (79-57, N3: the old
# block that switched warnings off loaded warnings.pm through PERL5LIB; they are off
# without -w anyway).
# 79-55 R1 (WR-02): the allowlist is SECURE_EXEC_ENV_NAMES, interpolated
# into the code, so sender and wrapper can never disagree. 79-55 R2
# (WR-01 R2): the item parser takes any name up to the first =, so %ok is
# the only name gate and a new constant entry needs no second edit.
sub _secureExecWrapperCode {
	my $names = join(' ', SECURE_EXEC_ENV_NAMES);
	(my $code = <<'END_WRAPPER') =~ s/__SECURE_EXEC_ENV_NAMES__/$names/;
my %ok = map { $_ => 1 } qw(__SECURE_EXEC_ENV_NAMES__);
my (%set, $sep);
while (@ARGV) {
	my $item = shift @ARGV;
	if ($item eq '--') { $sep = 1; last; }
	if ($item =~ /\A([^=]+)=(.*)\z/s && $ok{$1}) { $set{$1} = $2; next; }
	last;
}
unless ($sep && @ARGV) {
	print STDERR "[spoton-exec] bad wrapper arguments\n";
	exit 2;
}
@ARGV = map { /\A(.*)\z/s; $1 } @ARGV;
for my $n (keys %set) { ($set{$n}) = $set{$n} =~ /\A(.*)\z/s; }
for my $n (qw(PATH IFS CDPATH ENV BASH_ENV TERM)) {
	next unless defined $ENV{$n};
	($ENV{$n}) = $ENV{$n} =~ /\A(.*)\z/s;
}
$ENV{PATH} = '/usr/bin:/bin' if ${^TAINT};
my $egid = 0 + $);
$( = $egid;
$< = $>;
my ($ru, $eu, $rg, $eg) = ($<, $>, 0 + $(, 0 + $));
if ($ru != $eu || $rg != $eg) {
	print STDERR "[spoton-exec] could not set real ids to effective ids: ruid=$ru euid=$eu rgid=$rg egid=$eg\n";
}
$ENV{$_} = $set{$_} for sort keys %set;
my $err;
eval { exec { $ARGV[0] } @ARGV };
$err = $@ ? $@ : "$!";
chomp $err;
print STDERR "[spoton-exec] exec failed: $err\n";
exit 127;
END_WRAPPER
	return $code;
}

# _secureExecArgv(\%pairs, @args) -- the wrapper argv: $^X, -e, the code,
# a perl-level -- (79-55 R1, WR-01: perl consumes it, so the wrapper's own
# separator stays literal even with zero pairs), one NAME=VALUE per defined
# pair sorted by name, a literal --, then @args unchanged.
sub _secureExecArgv {
	my ($pairs, @args) = @_;
	return (
		$^X, '-e', _secureExecWrapperCode(), '--',
		(map { "$_=$pairs->{$_}" } grep { defined $pairs->{$_} } sort keys %$pairs),
		'--', @args,
	);
}

# _spawnProcess($self, \@args, $stderr_fh, $httpPortFile) -- Phase 83.3 plan
# 03: factored out of start() (env save/set, Proc::Background->new, env
# restore, PLUS the STDERR untie/retie that must bracket the same fork) so
# the D-06 smoke test below can spawn a throwaway instance through the exact
# same code path a real per-player daemon uses. Returns ($proc, $spawnError)
# -- never dies. $httpPortFile may be undef (the smoke test has no HTTP
# announce consumer); when defined it is exported as
# SPOTON_SOLOIST_HTTP_PORT_FILE exactly as start() already did.
sub _spawnProcess {
	my ($self, $args, $stderr_fh, $httpPortFile) = @_;

	require Proc::Background;

	# T-29-09 MANDATORY: untie STDERR before fork (Daemon.pm precedent) --
	# LMS ties STDERR to Slim::Utils::Log::Trapper; the child would die on
	# 'open STDERR, ...' dispatch if it stays tied during fork.
	my $had_stderr_tie = defined tied(*STDERR);
	untie *STDERR if $had_stderr_tie;

	require Plugins::SpotOn::Soloist;
	my $libPath       = Plugins::SpotOn::Soloist::libPath();
	my $libSearchPath = Plugins::SpotOn::Soloist::libSearchPath();

	my $savedLdLibraryPath = $ENV{LD_LIBRARY_PATH};
	my $savedLdPreload     = $ENV{LD_PRELOAD};
	my $savedXdgRuntimeDir = $ENV{XDG_RUNTIME_DIR};
	my $hadXdgRuntimeDir   = exists $ENV{XDG_RUNTIME_DIR};

	# D-17: libSearchPath() is the per-arch shim dir (CI zip layout) or the
	# dev tree's Bin/fake-libpulse, plus Bin/fake-libpulse for the decoy.
	$ENV{LD_LIBRARY_PATH} = defined $libSearchPath
		? ($savedLdLibraryPath ? "$libSearchPath:$savedLdLibraryPath" : $libSearchPath)
		: $savedLdLibraryPath;
	# Soloist dlopen()s libpulse at runtime — LD_LIBRARY_PATH only resolves
	# NEEDED entries. LD_PRELOAD forces the fake library into the process at
	# startup so the constructor runs immediately and the HTTP port is
	# announced before the WS events arrive.
	if (defined $libPath) {
		my $soPath = File::Spec::Functions::catfile($libPath, 'libpulse.so.0');
		$ENV{LD_PRELOAD} = $savedLdPreload ? "$soPath:$savedLdPreload" : $soPath
			if -f $soPath;
	}
	$ENV{SPOTON_SOLOIST_HTTP_PORT_FILE} = $httpPortFile if defined $httpPortFile;
	$ENV{SPOTON_FAKEPULSE_DEBUG} = 1;
	# Pitfall 3 (RESEARCH): Soloist prefers PipeWire over PulseAudio when
	# available -- on a desktop LMS host with a live PipeWire session,
	# Soloist would play audio on the LMS host's own soundcard instead of
	# routing through fake-libpulse. Block PipeWire at the *connection*
	# level (runtime dir, remote socket, XDG_RUNTIME_DIR removal) so its
	# dlopen succeeds, init runs, but the socket connect fails -- that is
	# the code path that triggers the PulseAudio fallback. Do NOT poison
	# SPA_PLUGIN_DIR or PIPEWIRE_MODULE_DIR: that aborts init itself
	# (before the fallback branch) and Soloist never calls pa_context_*.
	# LD_LIBRARY_PATH also carries a decoy libpipewire-0.3.so.0 (invalid
	# ELF; lives in Bin/fake-libpulse, which libSearchPath() keeps on the
	# path in both layouts) so dlopen fails instantly on headless systems
	# with no real PW.
	$ENV{PIPEWIRE_RUNTIME_DIR} = '/nonexistent';
	$ENV{PIPEWIRE_REMOTE}      = '/nonexistent';
	delete $ENV{XDG_RUNTIME_DIR};

	# 79-55 (#184): with equal ids the argv stays byte-identical; with
	# differing ids (piCorePlayer) spawn through the secure-exec wrapper so
	# the loader keeps LD_PRELOAD / LD_LIBRARY_PATH. The LMS parent's ids are
	# never changed.
	my @spawnArgv = @$args;
	my %savedPerlEnv;
	if (_useSecureExec($<, $>, 0 + $(, 0 + $))) {
		if (-f $^X && -x _) {
			my %pairs;
			for my $name (SECURE_EXEC_ENV_NAMES) {
				$pairs{$name} = $ENV{$name} if defined $ENV{$name};
			}
			@spawnArgv = _secureExecArgv(\%pairs, @$args);
			# 79-57 N3: the wrapper perl starts without them (restored below)
			for my $name (SECURE_EXEC_PERL_ENV) {
				$savedPerlEnv{$name} = delete $ENV{$name} if exists $ENV{$name};
			}
			main::INFOLOG && $log->is_info && $log->info(sprintf(
				'Soloist spawn through the secure-exec wrapper (79-55): real uid %d, effective uid %d, real gid %d, effective gid %d',
				$<, $>, 0 + $(, 0 + $)));
		}
		else {
			$log->warn("cannot re-exec through perl ($^X is not an executable file); starting soloist directly, the audio shim will not load on this host");
		}
	}

	my $proc;
	eval {
		$proc = Proc::Background->new(
			{ 'die_upon_destroy' => 1,
			  ($stderr_fh ? (stdout => $stderr_fh, stderr => $stderr_fh) : ()) },
			@spawnArgv,
		);
	};
	my $spawnError = $@;

	delete $ENV{SPOTON_SOLOIST_HTTP_PORT_FILE};
	delete $ENV{SPOTON_FAKEPULSE_DEBUG};
	delete $ENV{PIPEWIRE_RUNTIME_DIR};
	delete $ENV{PIPEWIRE_REMOTE};
	if (defined $savedLdPreload)     { $ENV{LD_PRELOAD} = $savedLdPreload; }
	else                             { delete $ENV{LD_PRELOAD}; }
	if (defined $savedLdLibraryPath) { $ENV{LD_LIBRARY_PATH} = $savedLdLibraryPath; }
	else                             { delete $ENV{LD_LIBRARY_PATH}; }
	if ($hadXdgRuntimeDir) { $ENV{XDG_RUNTIME_DIR} = $savedXdgRuntimeDir; }
	$ENV{$_} = $savedPerlEnv{$_} for keys %savedPerlEnv;

	tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;

	return ($proc, $spawnError);
}

# _watchExit($self, $proc) -- Phase 83.3 plan 15 (G-83.3-3 root cause): LMS
# runs libev's default loop (Slim::Networking::IO::Select uses EV::loop), and
# libev's childcb reaps every child via waitpid(-1) as soon as it exits (EV.pm
# POD: "EV will fetch the outstanding exit/wait status for all changed/zombie
# children"). By the time anything calls Proc::Background's own wait() the
# process is already gone; Proc::Background::Unix::_waitpid then gets ECHILD
# and fabricates "(1, 0) -- already reaped, exit status unknown"
# (Unix.pm:185-187), so a raw `$proc->wait >> 8` read always reports 0, never
# the real code. An EV::child watcher registered in the SAME Perl callback as
# the spawn -- before control returns to the loop -- observes the real status
# first: libev's child watchers carry EV_MAXPRI, so within one loop iteration
# the child event is delivered before libev's own reaping can lose it for
# anyone else. Resets both fields on every call (a stale recorded status must
# never leak from a previous spawn into this one). Returns 0 (no-op) unless a
# live $proc with a pid was given AND EV is loadable (test harnesses and any
# LMS build without EV both fall through to exitCode()'s Proc::Background
# fallback, unchanged). The watcher itself is kept on the daemon object
# (_exitWatcher) so it isn't garbage-collected before it fires; its closure
# holds a WEAKENED copy of $self (no self-reference cycle -- the watcher must
# never keep the daemon object alive past its own natural lifetime).
sub _watchExit {
	my ($self, $proc) = @_;

	$self->_exitStatus(undef);
	if (my $oldWatcher = $self->_exitWatcher) {
		eval { $oldWatcher->stop; 1 };
		$self->_exitWatcher(undef);
	}

	return 0 unless $proc && $proc->pid;

	unless (defined $haveEV) {
		$haveEV = eval { require EV; 1 } ? 1 : 0;
	}
	return 0 unless $haveEV;

	my $weak = $self;
	weaken($weak);

	my $w = EV::child($proc->pid, 0, sub {
		my $watcher = shift;
		$weak->_exitStatus($watcher->rstatus) if $weak;
		$watcher->stop;
	});
	$self->_exitWatcher($w);
	return 1;
}

# exitCode($self, $proc?) -- best-effort exit code for a dead (or dying)
# Soloist process. Reads the watcher-recorded status FIRST (the only
# reliable source once libev has reaped the child); falls back to
# Proc::Background's own wait() only when the watcher never fired -- either
# Proc::Background itself reaped the child first (its own alive()/wait()
# call ran before the loop ever got a chance to dispatch the child event),
# or EV was never available in this process. $proc defaults to $self->_proc
# so existing call sites that never captured their own $proc keep working
# unchanged. Returns undef when the code truly cannot be determined at
# all (no watcher status AND no live/waitable $proc).
#
# Phase 83.3 plan 17 (IN-01): 0 is ambiguous on the fallback path --
# Proc::Background's own wait() reports a lost/unreaped status as a hard
# 0 (CPAN Proc/Background.pm's ECHILD branch), indistinguishable from a
# real exit-0. Only the watcher-recorded status (the production path,
# t/33 1b) is authoritative; a caller reading a 0 from the fallback path
# must not treat it as "exited cleanly, definitely not 10".
sub exitCode {
	my ($self, $proc) = @_;
	$proc //= $self->_proc;

	my $status = $self->_exitStatus;
	unless (defined $status) {
		return undef unless $proc;
		return undef if $proc->alive;
		$status = eval { $proc->wait };
		return undef if $@ || !defined $status;
	}
	return $status >> 8;
}

sub start {
	my $self = shift;

	# soloist is Linux-only (Soloist.pm _arch()); this module must still
	# compile and no-op on Windows (soloist never runs there, but the
	# module is `require`d unconditionally by DaemonManager).
	return if main::ISWINDOWS;

	# WR-02 (82-REVIEW.md): the crash-respawn path calls start() WITHOUT a
	# preceding stop() -- _pollWsPort below unconditionally overwrites
	# _control/_ws with fresh objects, and the OLD Control's watchdog timer
	# (WATCHDOG_ROUND_S) used to survive in the global timer register,
	# later firing `playlist jump +1` against the NEW daemon -- exactly the
	# blind jump D-02/D-03 abolished, now from an instance nobody observes
	# anymore. _shutdownExistingControl calls the old Control's `shutdown` (which
	# kills that watchdog timer) and the old WS's `disconnect`, in that
	# order, BEFORE anything new gets built below -- on every call, not
	# just the orderly stop()->start() cycle.
	$self->_shutdownExistingControl;

	require Proc::Background;
	require Plugins::SpotOn::Soloist;

	my $client = Slim::Player::Client::getClient($self->mac);
	unless ($client) {
		$log->warn("SpotOn Soloist daemon: no client found for MAC " . $self->mac);
		return;
	}

	my $binaryPath = Plugins::SpotOn::Soloist->get();
	my $key        = Plugins::SpotOn::Soloist::readKey();

	unless ($binaryPath) {
		$log->warn("SpotOn Soloist daemon: no binary found, cannot start");
		return;
	}
	unless ($key) {
		$log->warn("SpotOn Soloist daemon: no spak-key found, cannot start");
		return;
	}

	require Plugins::SpotOn::Unified::DaemonManager;
	$self->name(Plugins::SpotOn::Unified::DaemonManager->deviceNameForClient($client));

	my $dataDir  = Plugins::SpotOn::Soloist::dataDirForClient($self->mac);
	my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient($self->mac);

	require File::Path;
	for my $dir ($dataDir, $cacheDir) {
		next if -d $dir;
		unless (eval { File::Path::make_path($dir, { mode => 0700 }); 1 }) {
			$log->error("SpotOn Soloist daemon: failed to create $dir: " . ($@ || $!));
			return;
		}
	}

	# GH #208: prune the existing audio cache before EVERY spawn. Idempotent:
	# below the limit it deletes nothing. A cache that already grew past it
	# (11 GB seen) shrinks over the first starts after the update: a full scan,
	# then at least one and at most SOLOIST_PRUNE_BUDGET_S seconds of deletions
	# each time. Never blocks the start; smokeTest does not prune.
	eval { $self->_pruneSoloistCache($cacheDir, SOLOIST_CACHE_LIMIT_MB * 1024 * 1024, SOLOIST_PRUNE_BUDGET_S); 1 }
		or $log->warn("SpotOn Soloist daemon: cache prune failed: " . ($@ || 'unknown error'));

	# Crash-loop check (plain push -- soloist has no discovery flag to
	# disable; DaemonManager's CRASH_BACKOFF_* is the throttle for this
	# daemon class).
	push @{ $self->_startTimes }, time();

	# Pitfall 2 (RESEARCH): stale ws.port/ws.addr/soloist.pid survive a
	# SIGKILL/crash. Delete them before every spawn and only ever accept a
	# ws.port whose mtime is >= this spawn's timestamp -- otherwise the WS
	# client could connect to a dead or unrelated foreign process.
	$self->_spawnTime(time());
	for my $stale (qw(ws.addr ws.port soloist.pid)) {
		unlink catfile($dataDir, $stale);
	}

	my $initialVolume = int($client->volume // 40);    # RESEARCH A7: --help default is 40
	# Hoisted ahead of its former sole use-site below (stderr open-mode) so
	# _spawnArgs can also read it as the $verbose flag (83.2-01/D-03).
	my $diagMode = $prefs->get('diagnosticMode');
	my @args = $self->_spawnArgs($binaryPath, $key, $self->name, $dataDir, $cacheDir, $initialVolume, $diagMode ? 1 : 0);

	# T-73-05/WR-01 (unchanged accepted risk from Phase 72): never log the
	# raw key -- mask it before logging argv.
	if (main::INFOLOG && $log->is_info) {
		my @masked = @args;
		for (my $i = 0; $i < @masked - 1; $i++) {
			$masked[$i + 1] = '****' if $masked[$i] eq '-k';
		}
		$log->info("Starting SpotOn Soloist daemon:\n" . join(' ', @masked));
	}

	# Tempfile for the HTTP port announce (fake-libpulse writes the decimal
	# port here -- SPOTON_SOLOIST_HTTP_PORT_FILE, D-04).
	my ($http_fh, $http_tmpfile);
	eval {
		($http_fh, $http_tmpfile) = tempfile('spoton-soloist-http-XXXX',
			DIR => catdir($serverPrefs->get('cachedir'), 'spoton'),
			UNLINK => 0,
		);
	};
	if ($@ || !$http_tmpfile) {
		$log->error("SpotOn Soloist daemon: tempfile() failed for HTTP port capture: $@");
		return;
	}
	close($http_fh);
	unlink $http_tmpfile;    # fake-libpulse re-creates it (O_CREAT|O_TRUNC)

	# Pitfall 1 (Daemon.pm precedent): stderr ALWAYS captured (crash
	# classification must work in the DEFAULT, non-diagnostic config too).
	# Soloist itself logs to stdout (incl. the Pitfall 7 "client expires in
	# N days" line) -- Proc::Background redirects both stdout+stderr here.
	# $diagMode itself is hoisted above (also feeds _spawnArgs' $verbose).
	my $stderrFile  = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-soloist.log');

	# 74b-04: bound the log BEFORE the open (rotate above 10 MB, cut an
	# oversized one to its last 5 MB), and ALWAYS open in append mode: the
	# child then writes at EOF, so a later truncate from this process never
	# leaves a sparse file. The start offset taken below makes append mode
	# safe for stderrTail/_parseExpiryDays (they read only this run's part).
	$self->_rotateLogAtStart($stderrFile);
	my $stderr_fh;
	open($stderr_fh, '>>', $stderrFile)
		or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; undef $stderrFile; };

	if (main::ISWINDOWS && $stderr_fh) {
		close($stderr_fh);
		$stderr_fh = undef;
	}

	my ($proc, $spawnError) = $self->_spawnProcess(\@args, $stderr_fh, $http_tmpfile);
	$self->_proc($proc);

	if ($spawnError || !$self->_proc) {
		$log->warn("Failed to launch SpotOn Soloist daemon: $spawnError");
		unlink $http_tmpfile;
		return;
	}

	# Phase 83.3 plan 15 (G-83.3-3): arm the exit-status watcher immediately
	# after a successful spawn -- before anything else can give libev's
	# default loop a chance to reap the child first.
	$self->_watchExit($proc);

	$self->_stderrFile($stderrFile);
	$self->_stderrStartOffset($stderrFile && -f $stderrFile ? (-s $stderrFile || 0) : 0);

	# 74b-04: runtime cap of the log, re-armed by _logCapTick while alive.
	Slim::Utils::Timers::killTimers($self, \&_logCapTick);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + LOG_CAP_INTERVAL, \&_logCapTick);

	# Async polls: ws.port (data-dir) and HTTP port (tempfile). Neither
	# consumer (streamPortForClient, sync proxy, WS-connect) needs to
	# tolerate a not-yet-known port differently than the librespot daemon's
	# equivalent -- both already guard with `alive && _streamPort`.
	$self->_wsPortPollAttempts(0);
	Slim::Utils::Timers::killTimers($self, \&_pollWsPort);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollWsPort, $dataDir);

	$self->_httpPortTmpfile($http_tmpfile);
	$self->_httpPortPollAttempts(0);
	Slim::Utils::Timers::killTimers($self, \&_pollHttpPort);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollHttpPort);
}

# _copyLogTail($src, $dest, $keep) -- 74b-04: write the last $keep bytes of
# $src to $dest (replacing it), in 1 MB chunks, never slurping the file. The
# bytes go to a temp name first and are renamed over $dest, so a failure
# leaves the previous .1 intact; a failed copy also removes the temp file
# (WR-02), so a full or read-only disk cannot pile up partial tails.
# Returns 1 on success, 0 otherwise.
sub _copyLogTail {
	my ($src, $dest, $keep) = @_;

	my $tmp = "$dest.tmp";
	my $ok = eval {
		open(my $in, '<:raw', $src) or die "open $src: $!";
		my $size = -s $in;
		seek($in, $size > $keep ? $size - $keep : 0, 0) or die "seek $src: $!";

		open(my $out, '>:raw', $tmp) or die "open $tmp: $!";
		my $remaining = $keep;
		while ($remaining > 0) {
			my $n = read($in, my $buf, $remaining > 1048576 ? 1048576 : $remaining);
			die "read $src: $!" unless defined $n;
			last unless $n;
			print {$out} $buf or die "write $tmp: $!";
			$remaining -= $n;
		}
		close($out) or die "close $tmp: $!";
		close($in);
		rename($tmp, $dest) or die "rename $tmp: $!";
		1;
	};
	unless ($ok) {
		my $err = $@;
		unlink $tmp if -e $tmp;
		$log->warn("SpotOn Soloist daemon: log tail copy failed: $err");
	}
	return $ok ? 1 : 0;
}

# _rotateLogAtStart($self, $path) -- 74b-04: called by start() before the log
# is opened. A log above LOG_RUNTIME_CAP_BYTES keeps only its last
# LOG_KEEP_TAIL_BYTES in $path.1 and the live file is unlinked (start() opens
# a fresh one right after, exactly as after the rename below): a log that grew
# to 2.3 GB before this code existed must not survive whole as .1. A log above
# LOG_ROTATE_AT_START_BYTES is renamed to $path.1 (replacing an older .1).
sub _rotateLogAtStart {
	my ($self, $path) = @_;
	return unless defined $path && -f $path;

	my $size = -s $path || 0;
	return if $size <= LOG_ROTATE_AT_START_BYTES;

	if ($size > LOG_RUNTIME_CAP_BYTES) {
		_copyLogTail($path, "$path.1", LOG_KEEP_TAIL_BYTES)
			or return;    # keep the live file when the tail could not be saved
		unlink($path) or $log->warn("SpotOn Soloist daemon: cannot remove oversized log $path: $!");
	}
	else {
		rename($path, "$path.1")
			or $log->warn("SpotOn Soloist daemon: cannot rotate $path: $!");
	}
}

# _capLogNow($self) -- 74b-04: runtime cap. When the live log exceeds
# LOG_RUNTIME_CAP_BYTES its last LOG_KEEP_TAIL_BYTES move to .1 and the live
# file is truncated to 0 (never unlinked: the child keeps its append-mode
# handle), and the start offset is reset. Lines the daemon writes between the
# tail copy and the truncate can be lost, bounded to one LOG_CAP_INTERVAL
# window (T-74b-13, accepted for a debug log).
sub _capLogNow {
	my $self = shift;

	my $file = $self->_stderrFile;
	return unless $file && -f $file;
	return if (-s $file || 0) <= LOG_RUNTIME_CAP_BYTES;

	my $ok = eval {
		_copyLogTail($file, "$file.1", LOG_KEEP_TAIL_BYTES) or die "tail copy failed\n";
		open(my $fh, '+<', $file) or die "open $file: $!";
		truncate($fh, 0) or die "truncate $file: $!";
		close($fh);
		$self->_stderrStartOffset(0);
		1;
	};
	$log->warn("SpotOn Soloist daemon: log cap failed for " . ($self->mac // '?') . ": $@") unless $ok;
}

# _logCapTick($self) -- 74b-04: timer callback. Caps the log while the daemon
# is alive and re-arms itself; a dead daemon is not re-armed (start() arms
# the timer again on the next spawn).
sub _logCapTick {
	my $self = shift;

	return unless $self->alive;
	$self->_capLogNow;
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + LOG_CAP_INTERVAL, \&_logCapTick);
}

# deferTrackRequest($self, $uri, $posMs, $opts) -- 260914-qn1 (Signature C):
# ProtocolHandler::getNextTrack's Control-missing branch reaches here when a
# Soloist daemon OBJECT exists but its Control instance has not been built
# yet (before _pollWsPort's on_found fires). $opts carries the ORIGINAL
# successCb/errorCb/source/duration straight through -- replayed unchanged
# via Control->requestTrack once Control comes up (see on_found below).
sub deferTrackRequest {
	my ($self, $uri, $posMs, $opts) = @_;

	# Fall-5 (Verdraengung): a still-pending EARLIER deferral loses its one
	# shot the moment a newer request supersedes it -- byte-identical
	# convention to Control.pm:818-821/885-888.
	if (my $prevPending = $self->_pendingTrackRequest) {
		Slim::Utils::Timers::killTimers($self, \&_pendingTrackTimeout);
		$prevPending->{opts}{errorCb}->('PROBLEM_OPENING', 'superseded') if $prevPending->{opts}{errorCb};
	}

	$self->_pendingTrackRequest({ uri => $uri, posMs => $posMs, opts => $opts });
	require Plugins::SpotOn::Unified::DeferBudget;
	my $deadline = Plugins::SpotOn::Unified::DeferBudget::deadlineFor($opts);
	Slim::Utils::Timers::setTimer($self, $deadline, \&_pendingTrackTimeout);
}

# _pendingTrackTimeout($self) -- 260914-qn1: TTL fallback for a
# deferTrackRequest that never got resolved by on_found (Control never came
# up). Mirrors Control::_wsRetryTimeout's shape exactly: read+clear the
# pending field first (return if already undef -- already resolved),
# record the expiry on Status's errors[] ring (T-qn1-02: closes the exact
# silent-wedge defect class get-state-statt-play.md attributes to nine
# failed measurement rounds), then unconditionally fire errorCb with the
# SAME error text the pre-existing synchronous rejection used (T-77-10 --
# getNextTrack must never wedge indefinitely).
sub _pendingTrackTimeout {
	my $self = shift;

	my $pending = $self->_pendingTrackRequest or return;
	$self->_pendingTrackRequest(undef);

	eval {
		require Plugins::SpotOn::Status;
		Plugins::SpotOn::Status->recordError('warn', 'Soloist',
			($self->mac // '?') . ": deferred requestTrack for " . ($pending->{uri} // '?')
			. " timed out after " . PENDING_TRACK_TTL_S . "s (Control instance never came up)",
			($self->mac // '?') . ":pending-track:" . ($pending->{uri} // '?'));
		1;
	} or $log->warn("SpotOn Soloist daemon: recordError failed for " . ($self->mac // '?') . ": $@");

	$pending->{opts}{errorCb}->('PROBLEM_OPENING', 'Soloist daemon not ready') if $pending->{opts}{errorCb};
}

sub _pollWsPort {
	my ($self, $dataDir) = @_;

	return unless $self->_proc;    # stop() cleared state -- nothing to do

	my $wsPortFile = catfile($dataDir, 'ws.port');

	$self->_pollPortScaffold(
		attempts_get => sub { $self->_wsPortPollAttempts },
		attempts_set => sub { $self->_wsPortPollAttempts($_[0]) },
		# WS-only: a port file is only trusted if its mtime is at or after
		# _spawnTime -- a stale file left over from a previous daemon
		# instance at the same data-dir must never be read as this run's
		# port (T-77-04).
		read_port => sub {
			return undef unless -f $wsPortFile;
			my @stat = stat($wsPortFile);
			my $mtime = $stat[9] || 0;
			return undef unless $mtime >= ($self->_spawnTime || 0);
			return undef unless open(my $fh, '<', $wsPortFile);
			my $line = readline($fh);
			close($fh);
			return undef unless defined $line && $line =~ /^(\d+)\s*$/;
			return $1 + 0;
		},
		reschedule => sub {
			Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollWsPort, $dataDir);
		},
		# WS-only: an exhausted/dead-process poll calls stop() -- a daemon
		# that never announces its WS control port is unusable (T-77-05
		# does NOT apply here; this is the HTTP-only WR-07 protection).
		on_exhausted => sub {
			my ($procAlive) = @_;
			# Phase 83.3 plan 04 (D-07 criterion a): a daemon that never
			# reaches ready is exactly as disqualifying as a repeated crash
			# -- both branches below are "never announced ws.port", so both
			# report the SAME startup-failure criterion (with a distinct
			# reason string). Eval-guarded: this module must never die
			# because DaemonManager's rollback logic threw.
			#
			# Phase 83.3 plan 15 (G-83.3-3 part b): the DEAD branch (process
			# already exited) is the one place a real expired build is
			# actually likely to be observed FIRST -- Pitfall 7 says an
			# expired build exits with code 10 on launch, often before
			# ws.port ever appears. Reading exitCode() here classifies that
			# case as D-03 (park + immediate renewal) instead of handing it
			# to D-07's rollback: rolling back to the kept (older, closer to
			# its OWN expiry) generation would trade one countdown for a
			# shorter one and lose the renewal entirely. Both observers
			# (this poll and DaemonManager's 5s _streamAlivePoll) funnel
			# into the same _handleSoloistBuildExpiry.
			# Phase 83.3 plan 17 (WR-03): DaemonManager::noteExpiredExit's
			# registration guard -- not stopHelper() -- is what makes
			# double-handling structurally impossible. stopHelper() removes
			# the %helperInstances entry and (as of this plan) cancels these
			# very port-poll timers for a DEAD helper too, so whichever
			# observer wins the race normally leaves nothing for the other
			# to re-observe; the guard is the independent backstop that
			# still refuses a stale/unregistered object even if a timer
			# somehow fires anyway.
			if ($procAlive) {
				$log->warn("SpotOn Soloist daemon did not announce ws.port in time - stopping (mac="
					. $self->mac . ")");
				$self->stop();
				eval {
					require Plugins::SpotOn::Unified::DaemonManager;
					Plugins::SpotOn::Unified::DaemonManager->noteStartupFailure($self->mac, 'no_ws_port');
					1;
				} or $log->warn("SpotOn Soloist noteStartupFailure failed (mac=" . $self->mac . "): $@");
			}
			else {
				my $code = $self->exitCode;
				if (defined $code && $code == 10) {
					$log->warn("SpotOn Soloist daemon exit status 10 before ws.port -- expired build, D-03 renewal path (mac="
						. $self->mac . ")");
					eval {
						require Plugins::SpotOn::Unified::DaemonManager;
						Plugins::SpotOn::Unified::DaemonManager->noteExpiredExit($self);
						1;
					} or $log->warn("SpotOn Soloist noteExpiredExit failed (mac=" . $self->mac . "): $@");
				}
				else {
					$log->warn("SpotOn Soloist daemon exited before announcing ws.port (mac=" . $self->mac . ")");
					eval {
						require Plugins::SpotOn::Unified::DaemonManager;
						Plugins::SpotOn::Unified::DaemonManager->noteStartupFailure($self->mac, 'exited_before_ws_port');
						1;
					} or $log->warn("SpotOn Soloist noteStartupFailure failed (mac=" . $self->mac . "): $@");
				}
			}
		},
		on_found => sub {
			my ($port) = @_;

			$self->_wsPort($port);
			main::INFOLOG && $log->is_info && $log->info(
				"SpotOn Soloist daemon ws.port announced: $port (mac=" . $self->mac . ")"
			);

			# 73-02 Pitfall 7: the daemon is demonstrably up and its startup
			# banner (which includes the "client expires in N days" line)
			# has had time to flush to the stderr-capture file by the time
			# ws.port appears -- parse once per start, no re-poll needed
			# for a 90-day clock.
			$self->_parseExpiryDays;

			# 83.3-02 (D-12b/D-13): first-start write of the Spotify
			# streaming-quality setting -- the daemon is demonstrably up
			# and .device_id exists at this point (RESEARCH Q1).
			# onDaemonReady() itself gates on soloistQualityInitialised/
			# soloistQualityPending, so every start after the first is a
			# no-op call, not a repeated write (D-12: never fight the app).
			# Consequence: on the first daemon start after this release,
			# every existing player is initialised once and its app-side
			# setting is overwritten once with Automatic (D-13, accepted).
			eval {
				require Plugins::SpotOn::Soloist::Quality;
				Plugins::SpotOn::Soloist::Quality->onDaemonReady($self->mac);
				1;
			} or do {
				$log->warn("SpotOn Soloist onDaemonReady(quality) failed (mac=" . $self->mac . "): $@");
			};

			require Plugins::SpotOn::Unified::SoloistWS;
			$self->_ws( Plugins::SpotOn::Unified::SoloistWS->new(
				daemon => $self,
				mac    => $self->mac,
				port   => $port,
			) );

			# Phase 82 Plan 01 (Neuausrichtung §3.2): construct Control
			# alongside SoloistWS and hand it the transport seam BEFORE
			# connect() -- the very first frame (get_auth_state's reply)
			# must already reach Control, not a legacy handler. The
			# closure holds $ctl strongly; $ctl->daemon is 'weak' (no
			# cycle).
			require Plugins::SpotOn::Soloist::Control;
			my $ctl = Plugins::SpotOn::Soloist::Control->new(
				daemon => $self,
				mac    => $self->mac,
			);
			$self->_control($ctl);

			# 260914-qn1 (Signature C): replay a track request that arrived
			# while this daemon object existed but Control did not yet.
			# Placement is deliberate -- immediately after _control($ctl),
			# before _ws->onEvent/_ws->connect below. Passing the pending
			# request through $ctl->requestTrack may itself re-defer via
			# Control's own Schritt 1 (wsConnected still false here) --
			# that is CORRECT, not redundant (see the Wechselwirkung note
			# in the plan's <context>: two independent TTLs bound two
			# different waits). Do not try to detect/skip that second
			# deferral.
			if (my $pending = $self->_pendingTrackRequest) {
				Slim::Utils::Timers::killTimers($self, \&_pendingTrackTimeout);
				$self->_pendingTrackRequest(undef);
				$ctl->requestTrack($pending->{uri}, $pending->{posMs}, $pending->{opts});
			}

			$self->_ws->onEvent(sub { $ctl->onEvent(@_) });

			$self->_ws->connect;
		},
	);
}

sub _pollHttpPort {
	my $self = shift;

	my $tmpfile = $self->_httpPortTmpfile;
	return unless $tmpfile;    # stop() cleared state -- nothing to do

	$self->_pollPortScaffold(
		attempts_get => sub { $self->_httpPortPollAttempts },
		attempts_set => sub { $self->_httpPortPollAttempts($_[0]) },
		# HTTP-only: no mtime staleness check -- the tmpfile is unique per
		# daemon spawn (File::Temp), so there's no cross-instance leftover
		# risk the way there is for ws.port's fixed per-player path.
		read_port => sub {
			return undef unless -s $tmpfile;
			return undef unless open(my $fh, '<', $tmpfile);
			my $line = readline($fh);
			close($fh);
			return undef unless defined $line && $line =~ /^(\d+)\s*$/;
			return $1 + 0;
		},
		reschedule => sub {
			Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollHttpPort);
		},
		# HTTP-only (WR-07, T-77-05): exhausting attempts while the process
		# is alive does NOT call stop() -- fake-libpulse's HTTP server may
		# just be slow to bind/listen; keep the tmpfile path and the daemon
		# alive so ensureHttpPort() can re-poll on demand when the stream
		# URL is actually needed. A slow-but-eventual announcement must
		# never kill an otherwise-healthy daemon. Only a genuinely dead
		# process clears the tmpfile.
		on_exhausted => sub {
			my ($procAlive) = @_;
			if ($procAlive) {
				main::INFOLOG && $log->is_info && $log->info(
					"SpotOn Soloist daemon HTTP stream port not yet announced - will poll on demand (mac="
					. $self->mac . ")");
			}
			else {
				$log->warn("SpotOn Soloist daemon exited before announcing HTTP stream port (mac=" . $self->mac . ")");
				$self->_httpPortTmpfile(undef);
				unlink $tmpfile;
			}
		},
		on_found => sub {
			my ($port) = @_;

			# WR-07: unlink only THIS daemon's own tmpfile once the port is
			# successfully read. Never unlink while the daemon might still
			# need to write it (the idle-daemon path above).
			$self->_httpPortTmpfile(undef);
			unlink $tmpfile;

			$self->_streamPort($port);
			main::INFOLOG && $log->is_info && $log->info(
				"SpotOn Soloist daemon HTTP stream port announced: $port (mac=" . $self->mac . ")"
			);
		},
	);
}

# CR-S3 (Phase 77 Plan 02, RESEARCH Pitfall 4): the shared scaffold between
# _pollWsPort and _pollHttpPort -- ONLY the truly identical part (attempts-
# counter increment, procAlive check, reschedule-if-alive-and-under-max-
# attempts). The two functions' distinct success/failure bodies (WS mtime
# staleness guard + stop()-on-exhaustion; HTTP tmpfile unlink + no-stop-on-
# exhaustion, WR-07) stay as per-caller closures passed in here -- do NOT
# fold those into this helper (that is the exact regression Pitfall 4
# warns about: a slow-but-eventual HTTP port announcement must never stop
# an otherwise-healthy daemon).
sub _pollPortScaffold {
	my ($self, %args) = @_;

	my $attempts = ($args{attempts_get}->() || 0) + 1;
	$args{attempts_set}->($attempts);

	my $port      = $args{read_port}->();
	my $procAlive = $self->_proc && $self->_proc->alive;

	if (!defined $port && $procAlive && $attempts < PORT_POLL_MAX_ATTEMPTS) {
		$args{reschedule}->();
		return;
	}

	unless (defined $port) {
		$args{on_exhausted}->($procAlive);
		return;
	}

	$args{on_found}->($port);
}

sub ensureHttpPort {
	my ($self, $cb) = @_;

	return $cb->($self->_streamPort) if $self->_streamPort;
	return $cb->(undef) unless $self->_proc && $self->_proc->alive;

	my $tmpfile = $self->_httpPortTmpfile;
	return $cb->(undef) unless $tmpfile;

	my $attempts = 0;
	my $poll; $poll = sub {
		$attempts++;
		if (-s $tmpfile) {
			if (open(my $fh, '<', $tmpfile)) {
				my $line = readline($fh);
				close($fh);
				if (defined $line && $line =~ /^(\d+)\s*$/) {
					my $port = $1 + 0;
					$self->_streamPort($port);
					$self->_httpPortTmpfile(undef);
					unlink $tmpfile;
					main::INFOLOG && $log->is_info && $log->info(
						"SpotOn Soloist daemon HTTP stream port announced on demand: $port (mac=" . $self->mac . ")");
					undef $poll;
					return $cb->($port);
				}
			}
		}
		if ($attempts < PORT_POLL_MAX_ATTEMPTS && $self->_proc && $self->_proc->alive) {
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + PORT_POLL_INTERVAL, $poll);
		} else {
			$log->warn("SpotOn Soloist daemon HTTP stream port not available on demand (mac=" . $self->mac . ")");
			undef $poll;
			$cb->(undef);
		}
	};
	$poll->();
}

sub _cancelPortPolls {
	my $self = shift;
	Slim::Utils::Timers::killTimers($self, \&_pollWsPort);
	Slim::Utils::Timers::killTimers($self, \&_pollHttpPort);
	if (my $tmp = $self->_httpPortTmpfile) {
		unlink $tmp;
		$self->_httpPortTmpfile(undef);
	}
}

# _shutdownExistingControl($self) -- WR-02 (82-REVIEW.md): the ONE place that
# retires an existing Control/WS pair, shared by `start` (crash-respawn
# path, no preceding stop()) and `stop` (the orderly path) -- there must
# be exactly one teardown sequence, not two that can drift apart (that
# would be the next finding of this same class). eval-guarded per object:
# a failure tearing down the OLD pair must never block building the NEW
# one (start's caller) or leave the daemon undead (stop's caller).
#
# 73-02 backoff-interplay audit: SoloistWS::disconnect() already calls
# Slim::Utils::Timers::killTimers($ws, \&_reconnectTimer) internally --
# verified, no separate killTimers needed here. Without this, a stopped
# daemon's WS client could still fire a delayed reconnect attempt against
# a port that no longer belongs to it.
# Phase 82 Plan 01: Control is torn down BEFORE the WS disconnects -- any
# command still in flight is released with an error instead of left to
# hang, and the per-mac registry entry is freed.
sub _shutdownExistingControl {
	my $self = shift;

	# 260914-qn1 (Signature C): release a still-pending deferTrackRequest
	# BEFORE the Control/WS teardown below -- this is the ONE teardown
	# point start()'s pre-respawn path and stop() already share (WR-02
	# above), so the pending-request release lives here and both callers
	# get it for free. Message text ('Soloist daemon shut down') is
	# distinct from both the TTL-expiry text ('Soloist daemon not ready')
	# and Control's own shutdown text ('Soloist control shut down') so the
	# three release paths stay individually distinguishable in logs/tests.
	if (my $pending = $self->_pendingTrackRequest) {
		Slim::Utils::Timers::killTimers($self, \&_pendingTrackTimeout);
		$self->_pendingTrackRequest(undef);
		$pending->{opts}{errorCb}->('PROBLEM_OPENING', 'Soloist daemon shut down') if $pending->{opts}{errorCb};
	}

	if (my $ctl = $self->_control) {
		eval { $ctl->shutdown; 1 }
			or $log->warn("SpotOn Soloist daemon: Control shutdown failed for " . ($self->mac // '?') . ": $@");
		$self->_control(undef);
	}

	if (my $ws = $self->_ws) {
		eval { $ws->disconnect; 1 }
			or $log->warn("SpotOn Soloist daemon: WS disconnect failed for " . ($self->mac // '?') . ": $@");
		$self->_ws(undef);
	}
}

sub stop {
	my ($self, %o) = @_;
	my $onGone = $o{onGone};

	$self->_cancelPortPolls;
	Slim::Utils::Timers::killTimers($self, \&_logCapTick);

	$self->_shutdownExistingControl;

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info(
			"Quitting SpotOn Soloist daemon for " . $self->mac
		);
		# 79-61 (FULL-2 WR-01): non-blocking TERM-then-KILL (ProcStop); the
		# blocking Proc::Background die() held the event loop up to 10 s for
		# a daemon that ignores SIGTERM. $onGone runs once the process is
		# gone (at once in the normal case).
		require Plugins::SpotOn::Unified::ProcStop;
		Plugins::SpotOn::Unified::ProcStop->terminate($self->_proc,
			key => $self->mac, label => 'Soloist daemon ' . $self->mac, onGone => $onGone);
	}
	elsif ($onGone) {
		$onGone->();
	}

	$self->_wsPort(undef);
	$self->_streamPort(undef);
}

sub stopForSync {
	my $self = shift;
	# Phase 83.3 plan 17 (CR-01): a deliberate, in-code stop must never be
	# reclassified as a crash by the 5s _streamAlivePoll -- flag it, but
	# only when the helper was actually alive (a stop on an already-dead
	# helper has nothing to flag; DaemonManager's dead-helper gates check
	# alive() first anyway, so this guard is belt-and-suspenders).
	my $wasAlive = $self->alive;
	# 79-61 (FULL-2 WR-01): the sync subscription re-runs initHelpers 0.1 s
	# after this stop; a daemon that takes longer to exit would still read
	# as alive then and miss its restart -- re-run initHelpers once it is gone.
	$self->stop(onGone => $wasAlive ? \&_initHelpersSoon : undef);
	$self->_startTimes([]);
	$self->_stoppedDeliberately(1) if $wasAlive;
}

sub _initHelpersSoon {
	eval { require Plugins::SpotOn::Unified::DaemonManager; 1 } or return;
	Slim::Utils::Timers::killTimers('Plugins::SpotOn::Unified::DaemonManager', \&Plugins::SpotOn::Unified::DaemonManager::initHelpers);
	Slim::Utils::Timers::setTimer('Plugins::SpotOn::Unified::DaemonManager', Time::HiRes::time() + 0.1,
		\&Plugins::SpotOn::Unified::DaemonManager::initHelpers);
}

sub pid {
	my $self = shift;
	return $self->_proc && $self->_proc->pid;
}

sub alive {
	my $self = shift;
	return 1 if $self->_proc && $self->_proc->alive;
	return 0;
}

sub uptime {
	my $self = shift;
	return Time::HiRes::time() - ($self->_startTimes->[-1] || time());
}

# stderrTail($self, $maxBytes) -- identical semantics to Unified::Daemon's
# (D-03 crash classification reads this on both daemon classes uniformly).
sub stderrTail {
	my ($self, $maxBytes) = @_;
	$maxBytes ||= 8192;

	my $file = $self->_stderrFile;
	return '' unless $file && -f $file;

	my $text = eval {
		open(my $fh, '<', $file) or die "open failed: $!";
		my $size = -s $fh;
		my $start = $self->_stderrStartOffset || 0;
		# 74b-04: the log can be truncated under us (runtime cap, clear
		# logs); an offset beyond the current size reads from 0.
		$start = 0 if $start > $size;
		my $from  = ($size - $maxBytes > $start) ? $size - $maxBytes : $start;
		seek($fh, $from, 0);
		local $/;
		my $data = <$fh>;
		close($fh);
		$data;
	};
	return '' if $@ || !defined $text;
	return $text;
}

# _parseExpiryDays($self)
# 73-02 (Pitfall 7): soloist logs "client expires in N days" on stdout at
# startup (live-verified, RESEARCH). Bounded 8 KiB head-read of the
# per-player stderr/stdout capture file (Proc::Background redirects both
# here, see start()); host-global cache key -- the pinned binary is shared
# across all players, last writer wins is fine for a Settings display
# (73-04 consumes it). Called once per daemon start from _pollWsPort, no
# timer/re-poll -- a 90-day clock needs no finer granularity than that.
sub _parseExpiryDays {
	my $self = shift;

	my $file = $self->_stderrFile;
	return unless $file && -f $file;

	my $head = eval {
		open(my $fh, '<', $file) or die "open failed: $!";
		# WR-10: diagnosticMode opens this log '>>' (append) -- reading from
		# offset 0 would parse whatever the FIRST-ever run wrote (the oldest
		# head in the file), freezing `days` at that stale value forever.
		# Seek to this run's own start offset instead.
		# 74b-04: clamp - an offset beyond the (truncated) file reads from 0.
		my $off = $self->_stderrStartOffset || 0;
		$off = 0 if $off > (-s $fh || 0);
		seek($fh, $off, 0);
		read($fh, my $buf, 8192);
		close($fh);
		$buf;
	};
	return if $@ || !defined $head;

	return unless $head =~ /client expires in (\d+) days/;
	my $days = $1;

	eval {
		require Slim::Utils::Cache;
		require Plugins::SpotOn::Plugin;
		my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
		$cache->set('spoton_soloist_expiry_days', { days => $days, checked_at => time() }, 'never');
		1;
	};
}

# ---------------------------------------------------------------------------
# D-06 smoke test (Phase 83.3 plan 03) -- proves a freshly-downloaded
# renewal candidate actually starts and reports a fresh (>90-day) lifetime
# BEFORE it replaces the active binary. Runs in a throwaway data/cache dir
# under <root>/smoke/ (NEVER a real player's dir -- Soloist.pm:569-571
# anti-pattern) and is stopped the moment the expiry line is seen.
# ---------------------------------------------------------------------------

# _smokeVerdict($class, $head, $alive, $exitCode, $attempts) -- PURE
# classifier, no I/O, directly unit-testable. $head is the accumulated
# stdout/stderr buffer read so far (never a filehandle).
sub _smokeVerdict {
	my ($class, $head, $alive, $exitCode, $attempts) = @_;

	if (defined $head && $head =~ /client expires in (\d+) days/) {
		my $days = $1;
		my ($bannerVersion) = $head =~ /soloist\s+([\d.]+)/;
		return ('found', $days, $bannerVersion);
	}
	if (!$alive && defined $exitCode && $exitCode == 10) {
		return ('expired');
	}
	if (!$alive) {
		return ('exited', defined $exitCode ? $exitCode : -1);
	}
	if (($attempts || 0) >= SMOKE_POLL_MAX_ATTEMPTS) {
		return ('timeout');
	}
	return ('pending');
}

# 79-57 (79-REVIEW-55-FIX IN-05): pids of running smoke tests.
my %_smokePids;

# smokePids($class) -- the pids of smoke tests between spawn and verdict.
sub smokePids {
	return sort { $a <=> $b } keys %_smokePids;
}

# smokeTest($class, $binaryPath, $cb) -- spawns $binaryPath in a throwaway
# smoke dir with a real spak-key (readKey()) and watches its stdout/stderr
# for the "client expires in N days" line via an EVENT-DRIVEN pipe read
# (Slim::Networking::Select::addRead), never a poll on the happy path -- a
# poll on every LMS select() tick for up to 10s would be needlessly wasteful
# when the answer typically arrives within one scheduler wakeup. The
# Slim::Utils::Timers poll below is only the fallback for the dead/timeout
# branches _smokeVerdict can't observe from the pipe alone (process exit
# code, wall-clock timeout). $cb fires EXACTLY ONCE, on every branch:
#   found  -> $cb->(1, { days, version, lifetime_ms, gap_ms, ready_seen_before_kill })
#   expired/exited/timeout/no_key/spawn_failed -> $cb->(0, { reason => ... })
sub smokeTest {
	my ($class, $binaryPath, $cb) = @_;

	require Plugins::SpotOn::Soloist;
	my $key = Plugins::SpotOn::Soloist::readKey();
	unless ($key) {
		$cb->(0, { reason => 'no_key' });
		return;
	}

	require File::Path;
	my $smokeRoot = catdir(Plugins::SpotOn::Soloist::_rootDir(), 'smoke');
	File::Path::make_path($smokeRoot, { mode => 0700 }) unless -d $smokeRoot;

	require File::Temp;
	my $smokeDir = eval { File::Temp::tempdir('smoke-XXXXXX', DIR => $smokeRoot) };
	unless ($smokeDir) {
		$cb->(0, { reason => 'spawn_failed' });
		return;
	}

	my $dataDir  = catdir($smokeDir, 'data');
	my $cacheDir = catdir($smokeDir, 'cache');
	File::Path::make_path($dataDir,  { mode => 0700 });
	File::Path::make_path($cacheDir, { mode => 0700 });

	my @args = $class->_spawnArgs($binaryPath, $key, SMOKE_DEVICE_NAME, $dataDir, $cacheDir, 0, 0);

	# T-73-05/WR-01: never log the raw key -- mask it before logging argv.
	if (main::INFOLOG && $log->is_info) {
		my @masked = @args;
		for (my $i = 0; $i < @masked - 1; $i++) {
			$masked[$i + 1] = '****' if $masked[$i] eq '-k';
		}
		$log->info("Soloist smoke test starting:\n" . join(' ', @masked));
	}

	my ($rd, $wr);
	pipe($rd, $wr) or do {
		File::Path::remove_tree($smokeDir);
		$cb->(0, { reason => 'spawn_failed' });
		return;
	};

	my $throwaway = bless [], $class;    # daemon-shaped object, never registered in %helperInstances
	my ($proc, $spawnError) = $throwaway->_spawnProcess(\@args, $wr, undef);
	close($wr);

	# 79-57 (79-REVIEW-55-FIX IN-05): the orphan sweep spares the running
	# smoke candidate (DaemonManager->helperPids reads smokePids); the pid
	# leaves the set at the verdict, in $cleanup below.
	my $smokePid = $proc ? eval { $proc->pid } : undef;
	$_smokePids{$smokePid} = 1 if $smokePid;

	unless ($proc) {
		close($rd);
		File::Path::remove_tree($smokeDir);
		$log->warn("Soloist smoke test: spawn failed: " . ($spawnError || 'unknown error'));
		$cb->(0, { reason => 'spawn_failed' });
		return;
	}

	# Phase 83.3 plan 15 (G-83.3-3): same watcher the real start() arms --
	# the smoke test's own dead/expired verdicts (below) need the real exit
	# code just as much as production classification does.
	$throwaway->_watchExit($proc);

	my $buffer    = '';
	my $done      = 0;
	my $attempts  = 0;
	my $spawnTime = Time::HiRes::time();

	my ($readCb, $pollCb);

	# 79-61 (FULL-2 WR-01): the smoke process is stopped without blocking;
	# its throwaway data dir and its smokePids() entry (the orphan sweep
	# spares it) go only once it is gone -- at once in the normal case.
	my $gone = sub {
		File::Path::remove_tree($smokeDir);
		delete $_smokePids{$smokePid} if $smokePid;
	};
	my $stopProc = sub {
		require Plugins::SpotOn::Unified::ProcStop;
		Plugins::SpotOn::Unified::ProcStop->terminate($proc, label => 'Soloist smoke test', onGone => $gone);
	};

	my $cleanup = sub {
		if ($rd) {
			Slim::Networking::Select::removeRead($rd);
			close($rd);
			$rd = undef;
		}
		Slim::Utils::Timers::killTimers($throwaway, $pollCb);
		$gone->() unless $proc->alive;    # an alive process gets $gone from $stopProc
	};

	my $finish = sub {
		my ($ok, $info) = @_;
		return if $done;
		$done = 1;
		$cleanup->();
		$cb->($ok, $info);
	};

	$readCb = sub {
		return unless $rd;

		# EXACTLY one non-blocking sysread per invocation -- never a line
		# read, which could block the single-threaded LMS event loop.
		my $n = sysread($rd, my $chunk, 4096);
		if (!defined $n || $n == 0) {
			# End-of-stream: the child exited or closed its output. Leave
			# the verdict to the fallback poll's exit/expired branch.
			Slim::Networking::Select::removeRead($rd);
			close($rd);
			$rd = undef;
			return;
		}

		$buffer .= $chunk;
		$buffer = substr($buffer, -8192) if length($buffer) > 8192;

		my $alive    = $proc->alive;
		my $exitCode = $alive ? undef : $throwaway->exitCode($proc);
		my ($verdict, @rest) = $class->_smokeVerdict($buffer, $alive, $exitCode, $attempts);

		if ($verdict eq 'found') {
			my ($days, $bannerVersion) = @rest;
			my $killTime = Time::HiRes::time();
			$stopProc->();
			Slim::Networking::Select::removeRead($rd) if $rd;

			my $readySeen = ($buffer =~ /ready,/) ? 1 : 0;
			my $gapMs = eval {
				return undef unless $buffer =~
					/(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})[.,](\d+):?[^\n]*client expires in \d+ days/s;
				require Time::Local;
				my $epoch = Time::Local::timelocal($6, $5, $4, $3, $2 - 1, $1);
				my $printedMs = $epoch * 1000 + substr($7 . '000', 0, 3);
				return int($killTime * 1000) - $printedMs;
			};

			main::INFOLOG && $log->is_info && $log->info(sprintf(
				"Soloist smoke test stopped after %d ms (gap %s ms, ready_seen %d)",
				int(($killTime - $spawnTime) * 1000), (defined $gapMs ? $gapMs : '?'), $readySeen
			));

			$finish->(1, {
				days                   => $days,
				version                => $bannerVersion,
				lifetime_ms            => int(($killTime - $spawnTime) * 1000),
				gap_ms                 => $gapMs,
				ready_seen_before_kill => $readySeen,
			});
		}
	};

	Slim::Networking::Select::addRead($rd, $readCb);

	$pollCb = sub {
		shift;    # Slim::Utils::Timers passes $obj as the first callback arg
		return if $done;
		$attempts++;

		my $alive    = $proc->alive;
		my $exitCode = $alive ? undef : $throwaway->exitCode($proc);
		my ($verdict, @rest) = $class->_smokeVerdict($buffer, $alive, $exitCode, $attempts);

		if ($verdict eq 'expired') {
			$finish->(0, { reason => 'expired' });
			return;
		}
		if ($verdict eq 'exited') {
			my ($rc) = @rest;
			$finish->(0, { reason => "exited_rc_$rc" });
			return;
		}
		if ($verdict eq 'timeout') {
			$stopProc->();
			$finish->(0, { reason => 'no_expiry_line' });
			return;
		}

		Slim::Utils::Timers::setTimer($throwaway, Time::HiRes::time() + SMOKE_POLL_INTERVAL, $pollCb);
	};

	Slim::Utils::Timers::setTimer($throwaway, Time::HiRes::time() + SMOKE_POLL_INTERVAL, $pollCb);
}

1;
