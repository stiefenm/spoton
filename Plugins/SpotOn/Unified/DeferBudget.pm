package Plugins::SpotOn::Unified::DeferBudget;

# Phase 82 Plan 44 (Signatur C, Runde 44, D-12): the EINZIGE Stelle, die eine
# Zurueckstellungs-Frist berechnet. Vorher standen zwei unabhaengige
# Konstanten (Control::WS_RETRY_TTL_S, SoloistDaemon::PENDING_TRACK_TTL_S,
# beide 25s) an getrennten Stellen -- eine Weiterreichung durch mehrere
# Ebenen (ProtocolHandler -> DaemonManager -> SoloistDaemon -> Control)
# konnte sich dadurch auf bis zu 50s/75s aufaddieren, wenn jede Ebene ihre
# eigene TTL ab dem Moment ihres eigenen Aufrufs neu ansetzte. D-12 bindet
# stattdessen EIN Gesamtbudget von 20s ab der urspruenglichen Anforderung,
# unabhaengig davon, wie oft intern weitergereicht wird.
#
# Eigentuemerschaft (Revision 1 -- der urspruengliche Verdacht auf einen
# zirkulaeren `require` war falsch und wird hier zurueckgezogen): keines von
# Control.pm, DaemonManager.pm oder SoloistDaemon.pm requiret heute eines
# der beiden anderen zur Compile-Zeit (die zwei echten Kreuzbezuege,
# SoloistDaemon.pm -> DaemonManager.pm und DaemonManager.pm ->
# SoloistDaemon.pm, sind beides Laufzeit-`require`s innerhalb von Subs,
# keine `use`s -- das kann keinen Compile-Zyklus bilden). Der wahre Grund
# fuer eine vierte, freistehende Datei: keines der drei Module ist heute
# Eigentuemer der anderen beiden. Die Konstante in Control.pm zu platzieren
# zwaenge DaemonManager.pm eine neue, heute nicht bestehende Require-Kante
# auf (und umgekehrt) -- eine eigene, abhaengigkeitsfreie Datei vermeidet
# das, ohne einen der drei Peers willkuerlich zum Eigentuemer zu erklaeren.

use strict;
use warnings;

use Time::HiRes;

# D-12: 20s Gesamtbudget ab der urspruenglichen Anforderung (rund die
# doppelte Luft ueber dem gemessenen Schlechtfall von ~3-10s, siehe
# 82-CONTEXT.md D-12) -- ersetzt die bisherigen, unabhaengig gestaffelten
# 25s-Einzel-TTLs.
use constant TOTAL_DEFER_BUDGET_S => 20;

# deadlineFor($opts) -- liest eine bereits gesetzte Frist aus $opts weiter
# (Hand-off von einer frueheren Ebene) oder setzt sie einmalig, wenn diese
# Ebene die urspruengliche Anforderung ist. Derselbe Hashref $opts wird an
# allen Weiterreichungsstellen unveraendert durchgereicht (kein Kopieren) --
# jede Ebene liest dieselbe Frist, keine berechnet neu.
sub deadlineFor {
    my ($opts) = @_;
    return $opts->{deferDeadline} //= Time::HiRes::time() + TOTAL_DEFER_BUDGET_S();
}

1;
