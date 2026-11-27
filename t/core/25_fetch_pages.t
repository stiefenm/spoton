#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes ();

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
# 92-13 (GH #238): a queue, so that a test can step through the timers the plugin sets
our @queue;
sub setTimer   { my ($obj, $when, $cb, @args) = @_; push @queue, [ $obj, $when, $cb, @args ]; return }
sub killTimers { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    for my $fn (@_) {
        *{"${caller}::${fn}"} = \&{$fn};
    }
}
sub string  { $_[-1] }
sub cstring { $_[-1] }
1;
END

write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
sub subscribe       { }
sub addDispatch     { }
sub executeRequest  { }
1;
END

write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new  { bless {}, shift }
sub initPlugin { }
sub can  { 1 }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::PluginManager', <<'END');
package Slim::Utils::PluginManager;
sub isEnabled { 1 }
1;
END

write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
sub encode_json { '{}' }
sub decode_json { {} }
1;
END

write_stub($stub_dir, 'Digest::MD5', <<'END');
package Digest::MD5;
use parent 'Exporter';
our @EXPORT_OK = qw(md5_hex);
sub md5_hex { 'deadbeef' }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

# Load the module and initialize prefs
require Plugins::SpotOn::Plugin;

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });

# ============================================================
# Timer queue helpers (92-13): the Slim::Utils::Timers stub queues every setTimer call
# ============================================================
sub reset_timers { @Slim::Utils::Timers::queue = (); return }

# run_one_timer: runs the oldest queued timer, 1 when one ran, 0 when the queue was empty
sub run_one_timer {
    my $t = shift @Slim::Utils::Timers::queue or return 0;
    my ($obj, $when, $cb, @args) = @$t;
    $cb->($obj, @args);
    return 1;
}

# run_timers: steps until the queue is empty, returns the number of steps
sub run_timers {
    my $steps = 0;
    while (run_one_timer()) {
        die "run_timers: more than 10000 steps" if ++$steps > 10000;
    }
    return $steps;
}

# ============================================================
# make_api_fn: synthetic synchronous apiFn for _fetchPages tests
# ============================================================
#
# make_api_fn(\@requests, \@sourceItems, %opts) returns a coderef with
# signature ($accountId, $params, $cb) that:
#   - records every { offset, limit } request onto @requests
#   - serves item slices from @sourceItems
#   - opts{total}         override for the reported total (default: scalar @sourceItems)
#   - opts{fail_on}       1-indexed call number on which to invoke $cb->(undef, 'boom')
#   - opts{empty_at}      once requested offset >= this value, return an empty item slice
#   - opts{nested}        wrap the response as { tracks => { items => ..., total => ... } }
#   - opts{ignore_shrink} always return opts{page_limit} items (ignores the shrunk request limit)
#   - opts{page_limit}    the true page size to use with ignore_shrink
sub make_api_fn {
    my ($requests, $items, %opts) = @_;
    my $call_count = 0;
    my $total_val  = $opts{total} // scalar(@$items);

    return sub {
        my ($accountId, $params, $cb) = @_;
        $call_count++;
        push @$requests, { offset => $params->{offset}, limit => $params->{limit} };

        if ($opts{fail_on} && $call_count == $opts{fail_on}) {
            $cb->(undef, 'boom');
            return;
        }

        my $offset = $params->{offset};
        my @slice;
        if ($opts{empty_at} && $offset >= $opts{empty_at}) {
            @slice = ();
        } elsif ($offset <= $#$items) {
            my $limit = $opts{ignore_shrink} ? ($opts{page_limit} // $params->{limit}) : $params->{limit};
            my $end   = $offset + $limit - 1;
            $end = $#$items if $end > $#$items;
            @slice = @$items[$offset .. $end];
        }

        if ($opts{nested}) {
            $cb->({ tracks => { items => \@slice, total => $total_val } });
        } else {
            $cb->({ items => \@slice, total => $total_val });
        }
    };
}

# ============================================================
# Test 1: back-compat -- no startOffset/maxItems
# ============================================================
subtest 'Test 1: back-compat unbounded fetch' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 34);    # 35 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 35);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 10,
        done      => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is(scalar(@$items), 35, 'all 35 items delivered');
    is_deeply($items, \@source, 'items delivered in order');
    is($err, undef, 'no error');
    is($total, 35, 'safeTotal == 35');
    is_deeply([ map { $_->{offset} } @requests ], [0, 10, 20, 30], 'requests at offsets 0/10/20/30');
};

# ============================================================
# Test 2: startOffset
# ============================================================
subtest 'Test 2: startOffset' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 49);    # 50 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 50);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 10,
        startOffset => 20,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is($requests[0]{offset}, 20, 'first request offset == 20');
    is(scalar(@$items), 30, '30 items delivered (positions 20..49)');
    is_deeply($items, [ @source[20 .. 49] ], 'items are list positions 20..49');
    is($total, 50, 'safeTotal == 50');
};

# ============================================================
# Test 3: maxItems + shrunk last page
# ============================================================
subtest 'Test 3: maxItems + shrunk last page' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 99);    # 100 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 100);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 10,
        startOffset => 0,
        maxItems    => 25,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is_deeply([ map { $_->{limit} } @requests ], [10, 10, 5], 'requests use limits 10,10,5');
    is(scalar(@$items), 25, 'exactly 25 items delivered');
    is($total, 100, 'safeTotal advertises true API total (100)');
};

# ============================================================
# Test 4: JVL-06 mid-fill error clamp
# ============================================================
subtest 'Test 4: mid-fill error clamp (JVL-06)' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 259);    # 260 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 500, fail_on => 2);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 50,
        startOffset => 200,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is(scalar(@$items), 50, '50 items delivered before failure');
    is($err, 'boom', 'error propagated');
    is($total, 250, 'safeTotal clamped to 200+50=250, NOT 500');
};

# ============================================================
# Test 5: empty-page clamp / shrunken list
# ============================================================
subtest 'Test 5: empty-page clamp' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 39);    # 40 items available
    my $apiFn  = make_api_fn(\@requests, \@source, total => 400, empty_at => 30);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 10,
        startOffset => 0,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is($err, undef, 'no error');
    is(scalar(@$items), 30, '30 items delivered before empty page');
    is($total, 30, 'safeTotal clamped to startOffset+30=30, NOT 400');
};

# ============================================================
# Test 6: JVL-07 pageLimit 0 falls back to 50
# ============================================================
subtest 'Test 6: pageLimit 0 falls back to 50 (JVL-07)' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 59);    # 60 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 60);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 0,
        done      => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    ok(scalar(@requests) > 0, 'at least one request made');
    ok((!grep { $_->{limit} != 50 } @requests), 'every recorded request has limit == 50');
    is(scalar(@$items), 60, 'all 60 items delivered');
};

# ============================================================
# Test 7: extractTotal / extractItems -- nested total key
# ============================================================
subtest 'Test 7: extractTotal nested key' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 14);    # 15 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 15, nested => 1);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId    => 'acct1',
        apiFn        => $apiFn,
        pageLimit    => 10,
        extractItems => sub { $_[0]->{tracks}{items} || [] },
        extractTotal => sub { $_[0]->{tracks}{total} // 0 },
        done         => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is(scalar(@$items), 15, 'all 15 items delivered via nested extractItems');
    is($total, 15, 'safeTotal read via nested extractTotal');
    is_deeply([ map { $_->{offset} } @requests ], [0, 10], 'pagination continued using nested total');
};

# ============================================================
# Test 8: overshoot trim
# ============================================================
subtest 'Test 8: overshoot trim' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 19);    # 20 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 20, ignore_shrink => 1, page_limit => 10);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 10,
        startOffset => 0,
        maxItems    => 12,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is(scalar(@$items), 12, 'items trimmed to exactly maxItems (12) despite overshoot');
};

# ============================================================
# Test 9: _fetchAllPages wrapper delegates identically to Test 1
# ============================================================
subtest 'Test 9: _fetchAllPages wrapper delegation' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 34);    # 35 items
    my $apiFn  = make_api_fn(\@requests, \@source, total => 35);

    my ($items, $err);
    Plugins::SpotOn::Plugin::_fetchAllPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 10,
        done      => sub { ($items, $err) = @_; },
    });
    run_timers();

    is(scalar(@$items), 35, 'all 35 items delivered via wrapper');
    is_deeply($items, \@source, 'items delivered in order via wrapper');
    is($err, undef, 'no error via wrapper');
    is_deeply([ map { $_->{offset} } @requests ], [0, 10, 20, 30], 'wrapper requests match Test 1');
};

# ============================================================
# Test 10: maxItems 0 -- immediate empty done, zero apiFn calls
# ============================================================
subtest 'Test 10: maxItems 0' => sub {
    my @requests;
    my @source = map { { id => $_ } } (0 .. 9);
    my $apiFn  = make_api_fn(\@requests, \@source, total => 10);

    my ($items, $err, $total);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 10,
        startOffset => 5,
        maxItems    => 0,
        done        => sub { ($items, $err, $total) = @_; },
    });
    run_timers();

    is_deeply($items, [], 'empty item list');
    is($err, undef, 'no error');
    is($total, 5, 'safeTotal == startOffset (5)');
    is(scalar(@requests), 0, 'zero apiFn invocations');
};

# ============================================================
# 92-13 (GH #238 / forum #424): a page answered synchronously (cache hit) hands the
# next page to a 0-delay timer, so a warm list never holds the event loop for more than one page
# ============================================================
subtest 'Test 11 (#238-Y1): synchronous pages yield one timer tick each' => sub {
    reset_timers();
    my @requests;
    my @source = map { { id => $_ } } (0 .. 119);
    my $apiFn  = make_api_fn(\@requests, \@source, total => 120);

    my ($items, $err, $total, $calls) = (undef, undef, undef, 0);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 50,
        done      => sub { ($items, $err, $total) = @_; $calls++ },
    });

    is(scalar(@requests), 1, 'exactly 1 request after the call returns');
    is($calls, 0, 'done not called yet');
    my @q = @Slim::Utils::Timers::queue;
    is(scalar(@q), 1, 'exactly 1 queued timer');
    ok(!defined $q[0][0], 'timer object is undef');
    ok($q[0][1] <= Time::HiRes::time(), 'timer is due now, not later');

    ok(run_one_timer(), 'first timer step ran');
    is(scalar(@requests), 2, '2 requests after one step');
    is($calls, 0, 'done still not called after one step');

    ok(run_one_timer(), 'second timer step ran');
    is(scalar(@requests), 3, '3 requests after two steps');
    is($calls, 1, 'done called once');
    is_deeply($items, \@source, 'all 120 items delivered in order');
    is($total, 120, 'safeTotal 120');
    is($err, undef, 'no error');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'queue is empty');
};

subtest 'Test 12 (#238-Y2): a one-page list completes inside the call' => sub {
    reset_timers();
    my @requests;
    my @source = map { { id => $_ } } (0 .. 29);
    my $apiFn  = make_api_fn(\@requests, \@source, total => 30);

    my ($items, $total, $calls) = (undef, undef, 0);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 50,
        done      => sub { ($items, undef, $total) = @_; $calls++ },
    });

    is($calls, 1, 'done called before _fetchPages returned');
    is(scalar(@$items), 30, '30 items delivered');
    is($total, 30, 'safeTotal 30');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'no timer queued');
};

subtest 'Test 13 (#238-Y3): pages that arrive later continue directly, no timer' => sub {
    reset_timers();
    my @source = map { { id => $_ } } (0 .. 119);
    my (@requests, @pending);
    my $apiFn = sub {
        my ($accountId, $params, $cb) = @_;
        push @requests, { offset => $params->{offset}, limit => $params->{limit} };
        push @pending, $cb;
    };
    my $slice = sub {
        my ($o, $l) = @_;
        my $e = $o + $l - 1; $e = $#source if $e > $#source;
        return { items => [ @source[$o .. $e] ], total => 120 };
    };

    my ($items, $calls) = (undef, 0);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 50,
        done      => sub { ($items) = @_; $calls++ },
    });
    is(scalar(@requests), 1, '1 request after the call');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'no timer after the call');

    (shift @pending)->($slice->(0, 50));
    is(scalar(@requests), 2, 'firing callback 1 requests page 2 at once');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'still no timer');

    (shift @pending)->($slice->(50, 50));
    is(scalar(@requests), 3, 'firing callback 2 requests page 3 at once');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'still no timer');

    (shift @pending)->($slice->(100, 50));
    is($calls, 1, 'firing the last callback calls done');
    is_deeply($items, \@source, 'all 120 items delivered');
    is(scalar(@Slim::Utils::Timers::queue), 0, 'the queue stayed empty the whole time');
};

subtest 'Test 14 (#238-Y4): synchronous error on page 2 passes through the timer, clamp holds' => sub {
    reset_timers();
    my @requests;
    my @source = map { { id => $_ } } (0 .. 259);
    my $apiFn  = make_api_fn(\@requests, \@source, total => 500, fail_on => 2);

    my ($items, $err, $total, $calls) = (undef, undef, undef, 0);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId   => 'acct1',
        apiFn       => $apiFn,
        pageLimit   => 50,
        startOffset => 200,
        done        => sub { ($items, $err, $total) = @_; $calls++ },
    });

    is($calls, 0, 'done not called before the pump');
    run_timers();
    is($calls, 1, 'done called once after the pump');
    is(scalar(@$items), 50, 'the 50 items of page 1 delivered');
    is($err, 'boom', 'error propagated');
    is($total, 250, 'safeTotal clamped to 200+50=250, NOT 500');
};

subtest 'Test 15 (#238-Y5): the decision is per page - late page 1, synchronous pages 2 and 3' => sub {
    reset_timers();
    my @source = map { { id => $_ } } (0 .. 119);
    my (@requests, @pending);
    my $n = 0;
    my $apiFn = sub {
        my ($accountId, $params, $cb) = @_;
        push @requests, { offset => $params->{offset}, limit => $params->{limit} };
        if (++$n == 1) { push @pending, $cb; return }
        my $o = $params->{offset};
        my $e = $o + $params->{limit} - 1; $e = $#source if $e > $#source;
        $cb->({ items => [ @source[$o .. $e] ], total => 120 });
    };

    my ($items, $calls) = (undef, 0);
    Plugins::SpotOn::Plugin::_fetchPages({
        accountId => 'acct1',
        apiFn     => $apiFn,
        pageLimit => 50,
        done      => sub { ($items) = @_; $calls++ },
    });
    is(scalar(@requests), 1, 'page 1 requested, answer pending');

    (shift @pending)->({ items => [ @source[0 .. 49] ], total => 120 });
    is(scalar(@requests), 2, 'firing callback 1 requests page 2 directly');
    is(scalar(@Slim::Utils::Timers::queue), 1, 'exactly 1 timer left, for page 3');
    is($calls, 0, 'done not called yet');

    ok(run_one_timer(), 'one step');
    is($calls, 1, 'done delivered after the step');
    is_deeply($items, \@source, 'all items delivered');
};

done_testing();
