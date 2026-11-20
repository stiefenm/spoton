#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# 89-12: Plugins::SpotOn::PlayerMessage, the one way SpotOn tells the user of a
# player something. Gap of the 89-05 eye check (2026-11-19): the refused-key stop
# message went out through showBriefly only, which Material Skin has not shown
# since 2.10.2. The helper keeps showBriefly and adds Material's notification.
#
# The cells run the real module against doubles for the player, for
# Slim::Utils::PluginManager and for Slim::Control::Request. The only LMS module
# the helper loads is Slim::Utils::Log, defined right here, so the file reads
# nothing from an LMS tree of the host and CI sees the same doubles.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

our (@WARNS, @NOTES);

BEGIN {
    package Slim::Utils::Log;
    sub logger { return bless {}, 'Slim::Utils::Log' }
    sub warn   { shift; push @main::WARNS, join('', @_); return }
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::logger"} = \&logger;
    }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;
}

unshift @INC, $project_dir;

my $have = eval { require Plugins::SpotOn::PlayerMessage; 1 };
ok($have, 'require Plugins::SpotOn::PlayerMessage;') or diag($@);

{
    package FakeClient;
    sub new { my ($class, %a) = @_; return bless { id => 'aa:bb:cc:dd:ee:12', brief => [], %a }, $class }
    sub id  { return $_[0]{id} }
    sub showBriefly {
        my ($self, @a) = @_;
        die $self->{dies} if $self->{dies};
        push @{ $self->{brief} }, [@a];
        return;
    }
}

# A missing module or sub must show up as a failing cell, never as a die that
# hides every later cell: show() and _atLeast() are reached through eval.
sub show {
    my @a = @_;
    my $r = eval { Plugins::SpotOn::PlayerMessage::show(@a) };
    return $@ ? "DIED: $@" : $r;
}
sub at_least {
    my @a = @_;
    my $r = eval { Plugins::SpotOn::PlayerMessage::_atLeast(@a) };
    return $@ ? "DIED: $@" : $r;
}

my $MATERIAL = 'Plugins::MaterialSkin::Plugin';
my @TEXT     = ('Line one', 'Line two');
my $ID       = 'aa:bb:cc:dd:ee:12';

sub note_of {    # the request line of the one notification, or [] when there is not exactly one
    return (@NOTES == 1 && ref $NOTES[0][1] eq 'ARRAY') ? $NOTES[0][1] : [];
}

# --- no plugin manager at all (a harness that defines none) ----------------
{
    @NOTES = (); @WARNS = ();
    my $c = FakeClient->new;
    my $r = show($c, \@TEXT, { type => 'error' });
    ok(!defined $r && @{ $c->{brief} } == 1 && !@WARNS,
        'no_plugin_manager: show returns undef, shows the popup once and logs nothing');
}

# From here on LMS's two entry points exist, as in every running server.
our ($ENABLED, $PM_DIES);
{
    no strict 'refs';
    *{'Slim::Utils::PluginManager::isEnabled'} = sub {
        my ($class, $module) = @_;
        die "plugin manager boom\n" if $PM_DIES;
        return ($module // '') eq $MATERIAL ? $ENABLED : undef;
    };
    *{'Slim::Control::Request::notifyFromArray'} = sub { push @NOTES, [@_]; return };
}

# --- Material not enabled ---------------------------------------------------
{
    @NOTES = (); @WARNS = (); $ENABLED = undef;
    my $c = FakeClient->new;
    my $r = show($c, \@TEXT, { type => 'error' });
    ok(!defined $r && @{ $c->{brief} } == 1 && @NOTES == 0 && !@WARNS,
        'no_material_no_notify: without the Material plugin nothing is sent, the popup shows, nothing dies');
}

# --- the display call -------------------------------------------------------
{
    @NOTES = (); $ENABLED = undef;
    my $c = FakeClient->new;
    show($c, \@TEXT, { type => 'info' });
    my ($parts, @rest) = @{ $c->{brief}[0] || [ {} ] };
    is_deeply($parts, { jive => { type => 'popupplay', text => [@TEXT] } },
        'popup_only_by_default: the display hash carries the jive popup and no line');
    ok(@{ $c->{brief} } == 1 && !@rest, 'no_duration_no_args: showBriefly gets the display hash and nothing else');

    $c = FakeClient->new;
    show($c, \@TEXT, { type => 'error', line => 1, duration => 6 });
    ($parts, @rest) = @{ $c->{brief}[0] || [ {} ] };
    is_deeply($parts, { line => [@TEXT], jive => { type => 'popupplay', text => [@TEXT] } },
        'display_lines_on_request: with line the same text is on the display lines too');
    is_deeply(\@rest, [ { duration => 6 } ], 'duration_is_handed_on: duration reaches showBriefly as its second argument');
}

# --- the Material notification ----------------------------------------------
{
    @NOTES = (); @WARNS = (); $ENABLED = { version => '6.4.9' };
    my $c = FakeClient->new;
    my $r = show($c, \@TEXT, { type => 'info' });
    is(scalar @NOTES, 1, 'material_one_notification: one notification per message');
    is_deeply($NOTES[0], [ undef, [ 'material-skin', 'notification', 'info', 'Line one - Line two', undef, $ID, 15 ] ],
        'material_notification_shape: no client, type, the text joined with " - ", no title, the player id, 15 s');
    ok(!defined $r && @{ $c->{brief} } == 1, 'material_keeps_the_popup: the display call still happens once');
}
{
    my %sent;
    for my $v ('6.4.9', '6.4.14', '6.5.0', '6.10.0', '7.0.0', 'DEVELOPMENT') {
        @NOTES = (); $ENABLED = { version => $v };
        show(FakeClient->new, \@TEXT, { type => 'error' });
        $sent{$v} = note_of()->[2] // 'none';
    }
    is($sent{'6.4.9'},  'info', 'error_to_material_649_goes_out_as_info: 6.4.9 would show "Something went wrong!" for an error');
    is($sent{'6.4.14'}, 'info', 'error_to_material_6414_goes_out_as_info: the last release before the fix');
    is($sent{'6.5.0'},  'error', 'error_to_material_650_stays_error: the first version that shows an error text');
    is($sent{'6.10.0'}, 'error', 'error_to_material_6100_stays_error: versions compare by number, not by letter');
    is($sent{'7.0.0'},  'error', 'error_to_material_700_stays_error');
    is($sent{'DEVELOPMENT'}, 'info', 'error_to_material_dev_goes_out_as_info: a version that is no number proves nothing');

    @NOTES = (); $ENABLED = 1;
    show(FakeClient->new, \@TEXT, { type => 'error' });
    is(note_of()->[2] // 'none', 'info', 'error_without_version_goes_out_as_info: an enabled plugin without data');

    @NOTES = (); $ENABLED = { version => '6.5.0' };
    show(FakeClient->new, \@TEXT, { type => 'info' });
    is(note_of()->[2] // 'none', 'info', 'info_stays_info: a newer Material does not turn info into error');

    @NOTES = ();
    show(FakeClient->new, \@TEXT, {});
    is(note_of()->[2] // 'none', 'info', 'no_type_is_info');

    @NOTES = ();
    show(FakeClient->new, 'One text', { type => 'info' });
    is(note_of()->[3] // 'none', 'One text', 'single_text: a plain string is one line, nothing is joined');

    @NOTES = ();
    show(FakeClient->new(id => '02:00:00:86:00:02'), \@TEXT, { type => 'info' });
    is(note_of()->[5] // 'none', '02:00:00:86:00:02', 'player_id: the notification names the player the message is for');
}

# --- nothing here may die ---------------------------------------------------
{
    @NOTES = (); @WARNS = (); $ENABLED = { version => '6.4.9' };
    my $c = FakeClient->new(dies => "display boom\n");
    my $r = show($c, \@TEXT, { type => 'error' });
    is($r, "display boom\n", 'display_dies_error_comes_back: show returns the error text of the display call');
    is(scalar @NOTES, 1, 'display_dies_material_still_sent: the notification goes out all the same');
}
{
    @NOTES = (); @WARNS = (); $ENABLED = { version => '6.4.9' };
    local $PM_DIES = 1;
    my $c = FakeClient->new;
    my $r = show($c, \@TEXT, { type => 'error' });
    ok(!defined $r && @{ $c->{brief} } == 1 && @NOTES == 0,
        'plugin_manager_dies_no_die: show returns undef, the popup shows, nothing is sent');
    is_deeply(\@WARNS, [ "SpotOn: Material notification failed: plugin manager boom\n" ],
        'plugin_manager_dies_one_warn: one server.log line names the failure');
}
{
    @NOTES = (); @WARNS = (); $ENABLED = { version => '6.4.9' };
    my $c = FakeClient->new;
    my @r = map { show(@$_) } [ undef, \@TEXT, { type => 'info' } ], [ $c, [], { type => 'info' } ], [ $c, [ undef, '' ], { type => 'info' } ];
    ok(!(grep { defined } @r) && @{ $c->{brief} } == 0 && @NOTES == 0,
        'nothing_to_say: no player or no text means no display call and no notification');
    my $r = show($c, \@TEXT, 'not a hash');
    ok(!defined $r && @{ $c->{brief} } == 1 && (note_of()->[2] // '') eq 'info',
        'options_not_a_hash: read as no options');
}

# --- the version rule -------------------------------------------------------
{
    my @cases = (
        [ '6.5.0', 1 ], [ '6.5', 1 ], [ '6.5.1', 1 ], [ '6.10.0', 1 ], [ '10.0.0', 1 ], [ '7', 1 ],
        [ '6.4.14', 0 ], [ '6.4.9', 0 ], [ '5.11.0', 0 ], [ '6', 0 ],
        [ 'DEVELOPMENT', 0 ], [ '6.5.0-beta', 0 ], [ 'GIT-abc1234', 0 ], [ '', 0 ], [ undef, 0 ],
    );
    my @got  = map { at_least($_->[0], '6.5.0') } @cases;
    my @want = map { $_->[1] } @cases;
    is_deeply(\@got, \@want, 'at_least: dotted numbers compare part by part against 6.5.0, anything else is 0')
        or diag(join(' ', map { (defined $cases[$_][0] ? $cases[$_][0] : 'undef') . '=' . (defined $got[$_] ? $got[$_] : 'undef') } 0 .. $#cases));
}

done_testing();
