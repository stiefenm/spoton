package Plugins::SpotOn::Backend;

# Phase 84-07 (SEAM-6.2, soloist-neuausrichtung-plan.md §6.2): the backend
# registry. One role, two implementations; the core (Connect.pm,
# ProtocolHandler.pm, DaemonManager.pm) reaches a backend ONLY through
# Plugins::SpotOn::Unified::DaemonManager->backendFor($clientOrMac), which
# picks the class here by the validated `backend` pref.
#
# The class names are STRINGS and are `require`d on demand, never `use`d:
# that keeps this file free of any compile-time dependency on either side,
# so the amputation test (§6.3.2) can delete one backend's files and still
# load the core.
#
# Role contract (frozen in 84-07; later plans add lifecycle hooks, never
# change these):
#   ->new($mac), ->mac, ->daemonClass
#   ->control($verb, %args)  -> 'ok' | 'declined' | 'unsupported' | 'down'
#   ->notify($event, %args)  -> 'ok' | 'unsupported' | 'down'
#   ->query($what, %args)    -> scalar | undef
#   ->capabilities()         -> hashref (copy)
#   ->state()                -> hashref { mode status paired wsConnected alive observedTrack active }
#   ->streamUrl($client, $song, $kind)
#   events: both backends emit only the seven spottyconnect verbs
#           start change stop volume seek resume ready

use strict;
use warnings;

our %BACKENDS = (
    librespot => 'Plugins::SpotOn::Backend::Librespot',
    soloist   => 'Plugins::SpotOn::Backend::Soloist',
);

# names() -- the registered backend names, sorted. Callable as a function
# or as a class method (the invocant is ignored).
sub names {
    return sort keys %BACKENDS;
}

# classFor($name) -- the role class for $name, loaded on demand. Dies on an
# unknown name: the caller (DaemonManager::backendName) validates the pref
# against names() first, so a die here is a programming error, never a
# user-editable pref value reaching a request handler (T-84-24).
sub classFor {
    my $name = @_ > 1 ? $_[1] : $_[0];
    my $class = defined $name ? $BACKENDS{$name} : undef;
    die "Plugins::SpotOn::Backend: unknown backend '" . ($name // 'undef') . "'\n" unless $class;

    (my $file = "$class.pm") =~ s{::}{/}g;
    require $file;
    return $class;
}

# available() -- the registered names (names() order) whose role module
# loads. 84-12 (SEAM-6.3.2, W5): an amputated install still boots, because
# DaemonManager::backendName falls back to the first available backend
# instead of handing a missing name to classFor (which keeps dying, above).
# A name whose module fails to load is remembered in %UNAVAILABLE (with its
# error) and warned about ONCE per LMS run -- role modules do not appear
# on disk without a restart, so re-probing would only repeat the warning.
# Callable as a function or as a class method.
our %UNAVAILABLE;
sub available {
    my @ok;
    for my $name (names()) {
        next if exists $UNAVAILABLE{$name};
        if (eval { classFor($name); 1 }) {
            push @ok, $name;
            next;
        }
        (my $err = $@ // '') =~ s/\s+\z//;
        $UNAVAILABLE{$name} = $err;
        # Lazy: no compile-time dependency (the registry stays loadable on its own).
        require Slim::Utils::Log;
        Slim::Utils::Log::logger('plugin.spoton')->warn("Backend '$name' unavailable (role module does not load): $err");
    }
    return @ok;
}

1;
