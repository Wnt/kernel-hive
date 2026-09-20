#!/usr/bin/perl
# =============================================================================
# stations/multics/multics-term.pl — the visitor's terminal on the Multics FNP.
#
# Runs as the command of the station's xterm, in place of stock `telnet`. It
# exists because stock telnet gets three things wrong for an exhibit, all three
# MEASURED on this station's own framebuffer 2026-09-20:
#
#  1. It opens on its own plumbing — "Trying 127.0.0.1...", "Connected to
#     127.0.0.1.", "Escape character is 'off'." — which is 2026 and not 1969.
#
#  2. The FNP does not hand a fresh connection to Multics. It answers with
#     `HSLA Port (d.h000,d.h001,...,d.h031)?` — a 32-channel menu that fills a
#     third of an 80x24 screen — and waits for a line to be chosen. One CR
#     picks d.h000, but the menu is already on the visitor's screen by then.
#     This bridge answers that prompt itself and shows none of it, so the rest
#     scene is the Multics banner and nothing else.
#
#  3. A visitor who types `logout` — which is the correct way to leave a
#     Multics session, and is in this station's own type-in demo — gets
#     "Multics has disconnected you" and a DEAD TERMINAL. Every later visitor
#     then finds a station that does nothing, until the 60 s relaunch reset
#     happens to run. This bridge reconnects and comes back at a fresh login
#     banner, which is also what the FNP's own line discipline expects.
#
# Perl, not Python: the container rootfs is a debootstrap minbase and has no
# python3, but perl 5.40 comes in with the base packages. Core modules only.
#
# No escape character is offered on purpose: there is nothing for a visitor to
# fall out of the exhibit INTO.
# =============================================================================
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my $HOST = $ENV{MULTICS_FNP_HOST} || '127.0.0.1';
my $PORT = $ENV{MULTICS_PORT}     || 6180;

# Telnet protocol bytes. The FNP opens with WILL SGA / WILL ECHO / WILL BINARY;
# Multics echoes for itself, so those are exactly what we want and we agree to
# them. Anything it asks US to do we refuse, so the exhibit never negotiates a
# feature it cannot honour.
use constant { IAC => 255, SE => 240, SB => 250,
               WILL => 251, WONT => 252, DO => 253, DONT => 254 };

$| = 1;
system('stty raw -echo 2>/dev/null');
END { system('stty sane 2>/dev/null'); }

# Strip and answer telnet commands. Incomplete sequences stay in $$bufref for
# the next chunk — a command split across two reads must not be printed as
# garbage on the visitor's screen.
sub telnet_filter {
    my ($bufref, $sock) = @_;
    my $out = '';
    my $i   = 0;
    my $n   = length $$bufref;
    while ($i < $n) {
        my $c = ord substr($$bufref, $i, 1);
        if ($c != IAC) { $out .= substr($$bufref, $i, 1); $i++; next; }
        last if $i + 1 >= $n;                       # incomplete: keep for later
        my $cmd = ord substr($$bufref, $i + 1, 1);
        if ($cmd == IAC) { $out .= chr(IAC); $i += 2; next; }
        if ($cmd == WILL || $cmd == WONT || $cmd == DO || $cmd == DONT) {
            last if $i + 2 >= $n;                   # incomplete: keep for later
            my $opt = ord substr($$bufref, $i + 2, 1);
            my $rep = $cmd == WILL ? DO : $cmd == WONT ? DONT : WONT;
            eval { print {$sock} chr(IAC) . chr($rep) . chr($opt); 1 };
            $i += 3;
            next;
        }
        if ($cmd == SB) {
            my $end = index($$bufref, chr(IAC) . chr(SE), $i);
            last if $end < 0;                       # incomplete: keep for later
            $i = $end + 2;
            next;
        }
        $i += 2;
    }
    $$bufref = substr($$bufref, $i);
    return $out;
}

# One visitor session: connect, get past the FNP's channel menu without showing
# it, then pass bytes both ways until the far end hangs up.
sub session {
    my $sock = IO::Socket::INET->new(
        PeerAddr => $HOST, PeerPort => $PORT, Proto => 'tcp', Timeout => 10);
    return 0 unless $sock;
    $sock->autoflush(1);

    my $raw   = '';        # bytes not yet parsed for telnet commands
    my $seen  = '';        # clean text so far, for the two handshake matches
    my $state = 0;         # 0 need the HSLA prompt · 1 need the attach · 2 live
    my $since = time;
    my $sel   = IO::Select->new($sock, \*STDIN);

    while (1) {
        my @ready = $sel->can_read(0.2);
        for my $h (@ready) {
            if ($h == $sock) {
                my $chunk = '';
                my $got = sysread($sock, $chunk, 65536);
                return 1 if !defined $got || $got == 0;    # hangup -> reconnect
                $raw .= $chunk;
                my $clean = telnet_filter(\$raw, $sock);
                $clean =~ s/\0//g;    # Multics pads with NUL after CR
                next unless length $clean;
                if ($state == 2) { print $clean; next; }
                $seen .= $clean;
                if ($state == 0 && $seen =~ /HSLA Port/) {
                    print {$sock} "\r\n";
                    $state = 1;
                    $since = time;
                } elsif ($state == 1 && $seen =~ /Attached to line/) {
                    # Everything so far was plumbing. Wipe it, and let the
                    # Multics banner that follows be the whole scene.
                    print "\e[2J\e[H";
                    $state = 2;
                }
            } else {
                my $chunk = '';
                my $got = sysread(STDIN, $chunk, 4096);
                return 0 if !defined $got || $got == 0;
                # A visitor typing before the handshake is done would desync it.
                next if $state != 2;
                print {$sock} $chunk;
            }
        }
        # Never hang on the handshake: if the FNP is quiet, nudge it, and if it
        # still says nothing, show the visitor whatever it does say rather than
        # a blank screen.
        if ($state == 0 && time - $since > 10) {
            print {$sock} "\r\n";
            $state = 1;
            $since = time;
        } elsif ($state == 1 && time - $since > 15) {
            print "\e[2J\e[H";
            $state = 2;
        }
    }
}

while (1) {
    my $again = session();
    last unless $again;
    # The far end hung up (a `logout`, or the reset relaunch). Come back at a
    # fresh banner rather than leaving a dead terminal on the wall.
    print "\e[2J\e[H";
    sleep 1;
}
