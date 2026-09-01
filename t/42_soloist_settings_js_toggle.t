#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ============================================================
# Gap D-08 (71-03): the Settings UI's backend<->soloist-fields live JS
# toggle is server-rendered inline JS with no browser/DOM test tooling in
# this harness. Rather than grep for the presence of a handler (which can't
# fail if the logic inside it is wrong), this test extracts the exact IIFE
# from basic.html and *executes* it under Node with a minimal synthetic
# DOM, then fires real 'change' events and asserts the resulting
# style.display values -- a genuine behavioral check of the toggle logic,
# not just its existence.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $html_file   = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";

plan skip_all => "basic.html not found" unless -f $html_file;

my $node = `which node 2>/dev/null`;
chomp $node;
plan skip_all => "node not available in this environment" unless $node;

open(my $fh, '<', $html_file) or die "Cannot open basic.html: $!";
my $html = do { local $/; <$fh> };
close($fh);

# Extract the specific IIFE that wires the pref_backend onchange listener.
# Anchored on the 'var backendSelect' declaration to uniquely identify it
# among any other inline <script> IIFEs in the template.
my ($js) = $html =~ /(\(function\(\)\s*\{\s*\n\s*var backendSelect.*?\}\)\(\);)/s;

ok(defined $js && length $js, 'extracted the pref_backend toggle IIFE from basic.html')
    or BAIL_OUT("Could not locate the backendSelect IIFE in basic.html — template structure changed");

# Minimal synthetic DOM + Node harness: real 'change' event dispatch through
# addEventListener, not a hand-simulated call -- if the extracted code
# doesn't register a listener the way real code does, this harness will not
# fake success.
my $harness = <<'NODE_HARNESS';
function makeStyleEl(id, initialDisplay) {
    return { id: id, style: { display: initialDisplay }, _listeners: {},
        addEventListener: function(evt, fn) {
            this._listeners[evt] = this._listeners[evt] || [];
            this._listeners[evt].push(fn);
        },
        dispatch: function(evt) {
            (this._listeners[evt] || []).forEach(function(fn) { fn(); });
        }
    };
}

var backendSelect = makeStyleEl('pref_backend', null);
backendSelect.value = 'librespot';
var soloistFields = makeStyleEl('soloist-fields', 'none');
var librespotFieldsA = makeStyleEl('librespot-fields', 'block');
var librespotFieldsB = makeStyleEl('librespot-fields', 'block');

global.document = {
    getElementById: function(id) {
        if (id === 'pref_backend') return backendSelect;
        if (id === 'soloist-fields') return soloistFields;
        return null;
    },
    querySelectorAll: function(sel) {
        return [librespotFieldsA, librespotFieldsB];
    }
};

// --- injected extracted template JS ---
EXTRACTED_JS_PLACEHOLDER
// --- end injected JS ---

var results = {};

// Simulate: user selects "soloist"
backendSelect.value = 'soloist';
backendSelect.dispatch('change');
results.afterSelectSoloist = {
    soloistDisplay: soloistFields.style.display,
    librespotADisplay: librespotFieldsA.style.display,
    librespotBDisplay: librespotFieldsB.style.display
};

// Simulate: user switches back to "librespot"
backendSelect.value = 'librespot';
backendSelect.dispatch('change');
results.afterSelectLibrespot = {
    soloistDisplay: soloistFields.style.display,
    librespotADisplay: librespotFieldsA.style.display,
    librespotBDisplay: librespotFieldsB.style.display
};

console.log(JSON.stringify(results));
NODE_HARNESS

$harness =~ s/EXTRACTED_JS_PLACEHOLDER/$js/;

my $script_path = "$test_dir/.tmp_soloist_toggle_harness.js";
open(my $out, '>', $script_path) or die "Cannot write harness: $!";
print $out $harness;
close($out);

my $result_json = `node "$script_path" 2>&1`;
my $node_exit = $? >> 8;
unlink $script_path;

is($node_exit, 0, 'extracted JS executed under Node without error')
    or diag("Node output: $result_json");

SKIP: {
    skip "Node execution failed, cannot parse result", 6 if $node_exit != 0;

    require JSON::PP;
    my $results = eval { JSON::PP::decode_json($result_json) };
    ok($results, 'Node harness produced valid JSON output') or diag("Raw output: $result_json");

    SKIP: {
        skip "No parseable JSON result", 5 unless $results;

        is($results->{afterSelectSoloist}{soloistDisplay}, 'block',
            'D-08: selecting "soloist" shows #soloist-fields live (no reload)');
        is($results->{afterSelectSoloist}{librespotADisplay}, 'none',
            'D-08: selecting "soloist" hides #librespot-fields instance A live');
        is($results->{afterSelectSoloist}{librespotBDisplay}, 'none',
            'D-08: selecting "soloist" hides #librespot-fields instance B live');

        is($results->{afterSelectLibrespot}{soloistDisplay}, 'none',
            'D-08: switching back to "librespot" hides #soloist-fields live');
        is($results->{afterSelectLibrespot}{librespotADisplay}, 'block',
            'D-08: switching back to "librespot" re-shows #librespot-fields live');
    }
}

done_testing();
