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

use File::Glob qw(bsd_glob);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempfile);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# M12-style async port-announcement poll -- 0.1s interval, 100 attempts (10s
# cap). Mirrors Unified::Daemon's PORT_POLL_INTERVAL/PORT_POLL_MAX_ATTEMPTS.
use constant PORT_POLL_INTERVAL     => 0.1;
use constant PORT_POLL_MAX_ATTEMPTS => 100;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	name
	_proc
	_startTimes
	_wsPort
	_streamPort
	_ws
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
) );
# NOTE: _accountId is left undef on purpose -- SoloistDaemon has no
# credentials.json/account concept (spak-key is server-wide), which gates
# DaemonManager's librespot-only audio-key cohort block off naturally
# (_streamAlivePoll checks `$helper->_accountId` before running it).
# NOTE: _lastHealthSession/_healthCheckCount exist for interface parity with
# Unified::Daemon (DaemonManager's health-poll code reads them generically)
# but fake-libpulse has no /health endpoint -- _streamAlivePoll gates that
# HTTP probe on `$helper->isa('Plugins::SpotOn::Unified::Daemon')`.

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

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

# _spawnArgs($binaryPath, $key, $name, $dataDir, $cacheDir, $initialVolume)
# PURE argv builder (testable without a live client/daemon context, t/28).
# -w 127.0.0.1:0 is a hard security requirement (T-73-01/RESEARCH V4) -- the
# WS control API has zero auth/TLS/origin checks; never a wildcard bind.
sub _spawnArgs {
	my ($class, $binaryPath, $key, $name, $dataDir, $cacheDir, $initialVolume) = @_;

	return (
		$binaryPath,
		'-n', $name,
		'-k', $key,
		'-D', $dataDir,
		'-C', $cacheDir,
		'-w', '127.0.0.1:0',
		'-i', $initialVolume,
	);
}

sub start {
	my $self = shift;

	# soloist is Linux-only (Soloist.pm _arch()); this module must still
	# compile and no-op on Windows (soloist never runs there, but the
	# module is `require`d unconditionally by DaemonManager).
	return if main::ISWINDOWS;

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
	my @args = $self->_spawnArgs($binaryPath, $key, $self->name, $dataDir, $cacheDir, $initialVolume);

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
	my $diagMode    = $prefs->get('diagnosticMode');
	my $stderrFile  = catfile($serverPrefs->get('cachedir'), 'spoton', $self->id . '-soloist.log');
	my $openMode    = $diagMode ? '>>' : '>';
	my $stderr_fh;
	open($stderr_fh, $openMode, $stderrFile)
		or do { $log->warn("Cannot open stderr log $stderrFile: $!"); undef $stderr_fh; undef $stderrFile; };

	if (main::ISWINDOWS && $stderr_fh) {
		close($stderr_fh);
		$stderr_fh = undef;
	}

	# T-29-09 MANDATORY: untie STDERR before fork (Daemon.pm precedent) --
	# LMS ties STDERR to Slim::Utils::Log::Trapper; the child would die on
	# 'open STDERR, ...' dispatch if it stays tied during fork.
	my $had_stderr_tie = defined tied(*STDERR);
	untie *STDERR if $had_stderr_tie;

	require Plugins::SpotOn::Soloist;
	my $libPath = Plugins::SpotOn::Soloist::libPath();

	my $savedLdLibraryPath = $ENV{LD_LIBRARY_PATH};
	my $savedXdgRuntimeDir = $ENV{XDG_RUNTIME_DIR};
	my $hadXdgRuntimeDir   = exists $ENV{XDG_RUNTIME_DIR};

	$ENV{LD_LIBRARY_PATH} = defined $libPath
		? ($savedLdLibraryPath ? "$libPath:$savedLdLibraryPath" : $libPath)
		: $savedLdLibraryPath;
	$ENV{SPOTON_SOLOIST_HTTP_PORT_FILE} = $http_tmpfile;
	# Pitfall 3 (RESEARCH): Soloist prefers PipeWire over PulseAudio when
	# available -- on a desktop LMS host with a live PipeWire session,
	# Soloist would play audio on the LMS host's own soundcard instead of
	# routing through fake-libpulse. Force the PipeWire probe to fail.
	$ENV{PIPEWIRE_RUNTIME_DIR} = '/nonexistent';
	delete $ENV{XDG_RUNTIME_DIR};

	eval {
		$self->_proc( Proc::Background->new(
			{ 'die_upon_destroy' => 1,
			  ($stderr_fh ? (stdout => $stderr_fh, stderr => $stderr_fh) : ()) },
			@args,
		) );
	};
	my $spawnError = $@;

	delete $ENV{SPOTON_SOLOIST_HTTP_PORT_FILE};
	delete $ENV{PIPEWIRE_RUNTIME_DIR};
	if (defined $savedLdLibraryPath) { $ENV{LD_LIBRARY_PATH} = $savedLdLibraryPath; }
	else                             { delete $ENV{LD_LIBRARY_PATH}; }
	if ($hadXdgRuntimeDir) { $ENV{XDG_RUNTIME_DIR} = $savedXdgRuntimeDir; }

	tie *STDERR, 'Slim::Utils::Log::Trapper' if $had_stderr_tie;

	if ($spawnError || !$self->_proc) {
		$log->warn("Failed to launch SpotOn Soloist daemon: $spawnError");
		unlink $http_tmpfile;
		return;
	}

	$self->_stderrFile($stderrFile);
	$self->_stderrStartOffset($stderrFile && -f $stderrFile ? (-s $stderrFile || 0) : 0);

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

sub _pollWsPort {
	my ($self, $dataDir) = @_;

	return unless $self->_proc;    # stop() cleared state -- nothing to do

	my $attempts = ($self->_wsPortPollAttempts || 0) + 1;
	$self->_wsPortPollAttempts($attempts);

	my $wsPortFile = catfile($dataDir, 'ws.port');
	my $port;

	if (-f $wsPortFile) {
		my @stat = stat($wsPortFile);
		my $mtime = $stat[9] || 0;
		if ($mtime >= ($self->_spawnTime || 0)) {
			if (open(my $fh, '<', $wsPortFile)) {
				my $line = readline($fh);
				close($fh);
				if (defined $line && $line =~ /^(\d+)\s*$/) {
					$port = $1 + 0;
				}
			}
		}
	}

	my $procAlive = $self->_proc && $self->_proc->alive;

	if (!defined $port && $procAlive && $attempts < PORT_POLL_MAX_ATTEMPTS) {
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollWsPort, $dataDir);
		return;
	}

	unless (defined $port) {
		if ($procAlive) {
			$log->warn("SpotOn Soloist daemon did not announce ws.port in time - stopping (mac="
				. $self->mac . ")");
			$self->stop();
		}
		else {
			$log->warn("SpotOn Soloist daemon exited before announcing ws.port (mac=" . $self->mac . ")");
		}
		return;
	}

	$self->_wsPort($port);
	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Soloist daemon ws.port announced: $port (mac=" . $self->mac . ")"
	);

	require Plugins::SpotOn::Unified::SoloistWS;
	$self->_ws( Plugins::SpotOn::Unified::SoloistWS->new(
		daemon => $self,
		mac    => $self->mac,
		port   => $port,
	) );
	$self->_ws->connect;
}

sub _pollHttpPort {
	my $self = shift;

	my $tmpfile = $self->_httpPortTmpfile;
	return unless $tmpfile;    # stop() cleared state -- nothing to do

	my $attempts = ($self->_httpPortPollAttempts || 0) + 1;
	$self->_httpPortPollAttempts($attempts);

	my $port;
	if (-s $tmpfile) {
		if (open(my $fh, '<', $tmpfile)) {
			my $line = readline($fh);
			close($fh);
			if (defined $line && $line =~ /^(\d+)\s*$/) {
				$port = $1 + 0;
			}
		}
	}

	my $procAlive = $self->_proc && $self->_proc->alive;

	if (!defined $port && $procAlive && $attempts < PORT_POLL_MAX_ATTEMPTS) {
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + PORT_POLL_INTERVAL, \&_pollHttpPort);
		return;
	}

	$self->_httpPortTmpfile(undef);
	unlink $tmpfile;
	for my $stale (bsd_glob(catfile(catdir($serverPrefs->get('cachedir'), 'spoton'), 'spoton-soloist-http-*'))) {
		unlink $stale;
	}

	unless (defined $port) {
		if ($procAlive) {
			$log->warn("SpotOn Soloist daemon did not announce HTTP stream port in time - stopping (mac="
				. $self->mac . ")");
			$self->stop();
		}
		else {
			$log->warn("SpotOn Soloist daemon exited before announcing HTTP stream port (mac=" . $self->mac . ")");
		}
		return;
	}

	$self->_streamPort($port);
	main::INFOLOG && $log->is_info && $log->info(
		"SpotOn Soloist daemon HTTP stream port announced: $port (mac=" . $self->mac . ")"
	);
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

sub stop {
	my $self = shift;

	$self->_cancelPortPolls;

	if ($self->_ws) {
		$self->_ws->disconnect;
		$self->_ws(undef);
	}

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info(
			"Quitting SpotOn Soloist daemon for " . $self->mac
		);
		$self->_proc->die;
	}

	$self->_wsPort(undef);
	$self->_streamPort(undef);
}

sub stopForSync {
	my $self = shift;
	$self->stop();
	$self->_startTimes([]);
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

1;
