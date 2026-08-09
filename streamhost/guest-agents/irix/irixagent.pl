#!/usr/bin/perl
#
# irixagent.pl — serial command agent for the Kernel Hive SGI IRIX 6.5 tile.
#
# Gives the tile a REAL exec channel — captured stdout+stderr and the guest's
# own exit code — over the emulated second serial port, the way the ssh and
# bridge tiles have one. The IRIX guest has no networking at all, so serial is
# the only wire; MAME's `indy_4610 -ioc2:rs232a pty` puts the host end on a
# /dev/pts slave and this agent owns the guest end, /dev/ttyd2.
#
# Perl 5.004 (what IRIX 6.5 ships as /usr/bin/perl) — no lexical filehandles,
# no `our`, no `//`, no Time::HiRes, no MIME::Base64. POSIX::Termios IS present
# (/usr/share/lib/perl5/irix-n32/5.00405/auto/POSIX/POSIX.so) and is used to put
# the line in the only mode a byte protocol can survive.
#
# ---------------------------------------------------------------- PROTOCOL ---
# irixser/2. Both directions: LF-terminated lines of printable 7-bit ASCII, and
# BOTH directions are checksummed (v1 checksummed only the replies, which meant
# a dropped byte in a request ran a DIFFERENT command and reported success).
#
#     <id> <verb> <sum> <payload>
#
# <sum> is a 4-hex-digit additive 16-bit checksum of "<id> <verb> <payload>" —
# the whole line with the sum field taken out. Framing is INSIDE the checksum on
# purpose: in v1 the id and the verb sat outside it, so the commonest corruption
# (a mangled id on the terminal X line) never reached the checksum logic and
# surfaced as a bogus timeout instead of a replay.
#
# Every payload (command text, output) is ESCAPED, so no framing byte can ever
# occur inside one:
#     \ -> \\        LF -> \n        CR -> \r
#     every other byte outside 0x20..0x7e -> \xHH (lowercase hex)
# Text expands ~1.0x, which matters: this wire runs at a few hundred bytes a
# second (see PACING). Base64 would cost 33% more and IRIX has no base64.
#
# host -> guest:
#     <id> PING <sum>
#     <id> RUN <sum> <opts> <esc-cmd>
#     <id> ABORT <sum> <target-id>
#     <id> RESULT <sum> <target-id>
# guest -> host:
#     <id> P <sum> irixser/2 <version> <src-sum>  (PING/ABORT reply, terminal)
#     <id> O <sum> <esc-chunk>           (0..N output chunks, <= 512 raw bytes)
#     <id> T <sum> <dropped> <esc-path>  (output capped; full text left on disk)
#     <id> X <sum> <status>              (RUN reply, terminal)
#     <id> E <sum> <esc-message>         (exec/protocol error, terminal)
#     <id> N <sum> <esc-message>         (NAK: request NOT run, resend it)
# <opts> is a comma-separated k=v list with NO spaces (the command is the rest
# of the line, so it may contain anything):
#     t=<secs>   guest-side timeout, 0 = none          (default 0)
#     o=<bytes>  cap on returned output                (default 4096)
#     p=idle|fast  pacing profile (see PACING)         (default idle)
#     d=1        detach: start it, do not wait         (default 0)
# <status>: 0..255 = the command's exit code; 256+N = killed by signal N;
# 257 = timed out; 258 = aborted by the host.
#
# WHAT HAPPENS WHEN A LINE IS CORRUPTED. The checksum earned its place: an
# `X 265` was seen arriving as `X 3,5`. That was first blamed on two agents
# interleaving their paced writes (see "single instance" below) — but it came
# back on a clone with exactly one agent, and the checksum on the garbled line
# was CORRECT FOR THE GARBLED TEXT, which is only possible if the agent itself
# rendered the number that way. So this perl can mis-stringify an integer, about
# one run in five, and no wire-level check can catch it; see the sprintf() in
# do_run and the client's recovery path. The check still earns its place:
# silently handing a caller a corrupted exit code or a corrupted line of output
# is the one failure this channel must not have.
#   * guest -> host: the agent REMEMBERS the last completed RUN (its exit status
#     and its output file), so `<id2> RESULT <id>` replays that whole reply.
#     The replay goes out under id2 — the REQUESTER's id, not the original's —
#     so the client can tell replayed lines from the tail of the original reply
#     that is still in flight. (v1 replayed under the original id, which made
#     the two indistinguishable and let a client return TRUNCATED output with a
#     success status.) A client that sees a bad checksum re-fetches rather than
#     re-running: the commands this channel exists for are not all idempotent.
#   * host -> guest: a request whose checksum does not verify — or which does
#     not parse at all — is NOT executed. The agent answers `N` and the client
#     re-sends the SAME line, id included. Re-sending is safe because a RUN is
#     idempotent in the id: a RUN whose id AND command checksum match the last
#     completed one is replayed, never re-run. (Without that, a NAK emitted for
#     leftover garbage that happened to precede a valid RUN would have made the
#     client re-send a command the agent had already accepted.)
#
# RESYNCHRONISATION is the id. A client picks a fresh id, and every reply line
# carries it, so anything left over from a client that died mid-reply — or the
# tail of a command the host gave up on — is unambiguous garbage the client
# drops. A client that wants a known-good line PINGs with a new id and reads
# until it sees that id.
#
# ------------------------------------------------------------------ PACING ---
# MAME's SCC85230 signals "transmitter empty" long before the byte has actually
# left, so IRIX's sduart driver overruns the emulated 4-byte TX FIFO and bytes
# are SILENTLY DROPPED. Measured on indy_4610 (1200-byte patterns, this exact
# golden): 4 bytes per write is lossless, 8 bytes per write loses 25%, 16 loses
# 37% — and it is the write SIZE that matters, not the byte rate. So every
# guest->host write is at most $CHUNK bytes with a delay after it:
#     p=idle  one select() per chunk  — ~140 B/s, and the agent SLEEPS, so it
#             costs the exhibit no emulated CPU. The default: this tile is
#             CPU-bound and every cycle is visible to a visitor.
#     p=fast  a calibrated busy-loop  — ~270 B/s, at 100% of one guest CPU for
#             the duration. Worth it for bulk output, not for `echo hi`.
# IRIX's clock tick makes any select() cost ~20 ms whatever timeout you ask for,
# which is why the busy-loop is faster than sleeping. Both numbers are wire
# measurements, not estimates; see docs/guests/irix.md.
#
# ABORT is honoured WHILE OUTPUT IS BEING SENT, not only while the command runs
# (v1 read the line again only after the whole capped output had been paced out,
# so a timed-out 16 KB reply blocked every later client for ~2 minutes).
#
# IDLE COST is zero: between requests the agent blocks in sysread() on the tty.
#
# INSTALLED as /usr/local/bin/irixagent.pl, started by irixagent.sh from an
# /etc/inittab respawn line. Baked into the golden by
# scripts/build-guests/irix/irix-serial-install.sh. The PING reply carries a checksum
# of THIS FILE as the guest has it, so `irixexec.py --ping --agent-src <repo
# copy>` says outright whether the baked agent is the one in the repo.

use POSIX qw(:sys_wait_h :termios_h setsid);
use Fcntl;

$PROTO   = "irixser/2";
$VERSION = "2.0";
$DEV     = defined($ENV{IRIXAGENT_DEV}) ? $ENV{IRIXAGENT_DEV} : "/dev/ttyd2";
$CHUNK   = defined($ENV{IRIXAGENT_CHUNK}) ? $ENV{IRIXAGENT_CHUNK} : 4;
$BUSY_FAST = defined($ENV{IRIXAGENT_BUSY}) ? $ENV{IRIXAGENT_BUSY} : 800;
$BUSY    = 0;
$LOGDIR  = defined($ENV{IRIXAGENT_LOGDIR}) ? $ENV{IRIXAGENT_LOGDIR} : "/var/tmp";
$OUTMAX  = 4096;
# The last completed RUN, kept for RESULT replay and for RUN de-duplication
# (see PROTOCOL). $LAST_CMD is the checksum of the escaped command text, so an
# id that happens to repeat with a DIFFERENT command is never mistaken for a
# re-send of the same one.
$LAST_ID     = "";
$LAST_CMD    = "";
$LAST_PATH   = "";
$LAST_MAX    = $OUTMAX;
$LAST_STATUS = 0;
$LINEMAX = 512;
$ABORTED = 0;
$REPLAY_TO = "";
$SRCSUM  = "----";

# The environment every command runs in. DISPLAY/XAUTHORITY are the point of the
# exercise: `labctl exec irix "/usr/demos/bin/buttonfly &"` has to land on the
# xdm session the visitor is looking at, and init gives us neither.
$ENV{PATH}       = "/usr/local/bin:/usr/sbin:/usr/bsd:/sbin:/usr/bin:/etc:/usr/etc";
$ENV{SHELL}      = "/bin/sh";
$ENV{HOME}       = "/" unless defined $ENV{HOME};
$ENV{TERM}       = "vt100" unless defined $ENV{TERM};
$ENV{DISPLAY}    = ":0" unless defined $ENV{DISPLAY};
$ENV{XAUTHORITY} = "/.Xauthority" unless defined $ENV{XAUTHORITY};

$SIG{PIPE} = 'IGNORE';
$SIG{HUP}  = 'IGNORE';

%ESC = ("\\" => "\\\\", "\n" => "\\n", "\r" => "\\r");

sub esc {
    my ($s) = @_;
    $s =~ s/([\x00-\x1f\x5c\x7f-\xff])/defined($ESC{$1}) ? $ESC{$1} : sprintf("\\x%02x", ord($1))/ge;
    return $s;
}

# Returns undef on a malformed escape — the caller answers E rather than
# guessing at what the host meant.
sub unesc {
    my ($s) = @_;
    my $out = "";
    my $i   = 0;
    my $n   = length($s);
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        $i++;
        if ($c ne "\\") { $out .= $c; next; }
        my $e = substr($s, $i, 1);
        $i++;
        if    ($e eq "n")  { $out .= "\n" }
        elsif ($e eq "r")  { $out .= "\r" }
        elsif ($e eq "\\") { $out .= "\\" }
        elsif ($e eq "x") {
            return undef if $i + 2 > $n;
            my $h = substr($s, $i, 2);
            return undef unless $h =~ /^[0-9a-fA-F]{2}$/;
            $out .= chr(hex($h));
            $i += 2;
        }
        else { return undef }
    }
    return $out;
}

sub sum16 { return sprintf("%04x", unpack("%32C*", $_[0]) & 0xffff) }

# ---- single instance --------------------------------------------------------
# TWO agents on one line is not a degraded mode, it is an unreadable one: both
# write to /dev/ttyd2 and their 4-byte paced writes INTERLEAVE, which arrives
# looking exactly like wire corruption (an `X 265` read back as `X 3,5`). That
# is not hypothetical — an install that killed the wrapper but not the perl left
# init respawning a second one, and it cost hours to see.
#
# The lock is an flock on a file we keep open for the life of the process, NOT a
# recorded pid. A pid lock has two holes that both bite here: writing the pid
# is not atomic (a lock file containing "/70" for pid 970 was observed on a
# clone, and a non-numeric lock silently disabled the liveness check), and
# kill(0,$pid) only asks whether SOME process has that pid — the agent's boot
# pid is deterministic on this golden, so a lock that ever survives into a baked
# image would make every future agent decline for ever, silently. flock has
# neither problem: the kernel releases it when the holder dies, whatever killed
# it. The pid is still written, as a breadcrumb for a human reading the file.
sub claim_line {
    my $lf = "$LOGDIR/irixagent.lock";
    sysopen(LOCK, $lf, O_RDWR | O_CREAT, 0644) or return 1;    # unwritable /var/tmp: start anyway
    my $ok = eval { flock(LOCK, 2 | 4) };                      # LOCK_EX|LOCK_NB
    if (defined $ok) {
        return 0 unless $ok;
        truncate(LOCK, 0);
        select((select(LOCK), $| = 1)[0]);
        print LOCK "$$\n";
        return 1;
    }
    # flock unimplemented. It IS implemented in IRIX 6.5's perl — the installer
    # asserts so at bake time — but a guard that vanishes silently on a build
    # that lacks it would take the whole single-instance property with it, so
    # fall back to the old pid test, holes and all.
    my $other = "";
    if (open(LKR, "<$lf")) { $other = <LKR>; close(LKR) }
    $other = "" unless defined $other;
    $other =~ s/\s+//g;
    return 0 if $other =~ /^\d+$/ && $other != $$ && kill(0, $other);
    open(LKW, ">$lf") or return 1;
    print LKW "$$\n";
    close(LKW);
    return 1;
}

# A detached run's output file outlives the run by design, and its id is random,
# so nothing ever reuses the name: without this sweep every boot accumulates
# them for the life of the tile (and a bake freezes the survivors into the
# golden). Startup is the only safe moment — mid-run they are live files.
sub sweep_outputs {
    local *D;
    opendir(D, $LOGDIR) or return;
    my $f;
    foreach $f (readdir(D)) {
        unlink("$LOGDIR/$f") if $f =~ /^irixexec-\d+\.out$/;
    }
    closedir(D);
}

# Checksum of this file as the GUEST has it. Reported in every PING reply, so
# "is the baked agent the one in the repo" is one command and not a golden
# mount. Cheap: ~18 KB read once at startup.
sub source_sum {
    local *S;
    open(S, "<$0") or return "----";
    binmode(S);
    my $data = "";
    my $buf;
    while (read(S, $buf, 8192)) { $data .= $buf }
    close(S);
    return sum16($data);
}

# ---- the line ---------------------------------------------------------------
# O_NOCTTY: init starts us as a session leader, and without it this tty would
# become our controlling terminal — after which a background read earns SIGTTIN
# and the agent stops, invisibly. One fd is held open for the whole life of the
# process: IRIX re-defaults the line discipline on a close/open transition, so a
# settings pass in a different process would silently evaporate.
sub open_line {
    sysopen(TTY, $DEV, O_RDWR | O_NOCTTY) or die "irixagent: open $DEV: $!\n";
    my $t = POSIX::Termios->new;
    $t->getattr(fileno(TTY)) or die "irixagent: tcgetattr: $!\n";
    # IGNBRK alone clears icrnl/inlcr/igncr/ixon/ixoff/ixany/istrip/inpck/brkint.
    # ixon is the dangerous one: a literal ^S anywhere in a command's output
    # would stop the port forever, and nothing would report it.
    $t->setiflag(IGNBRK);
    $t->setoflag(0);                              # -opost: no NL->CR-NL rewriting mid-payload
    $t->setcflag(CS8 | CREAD | CLOCAL);           # 8N1, no modem control (ttyd* has none)
    $t->setlflag(0);                              # -icanon -isig -echo -iexten
    $t->setcc(VMIN,  1);
    $t->setcc(VTIME, 0);
    $t->setispeed(B9600);
    $t->setospeed(B9600);
    $t->setattr(fileno(TTY), TCSANOW) or die "irixagent: tcsetattr: $!\n";
}

sub pace {
    if ($BUSY > 0) {
        my $x = 0;
        my $j;
        for ($j = 0 ; $j < $BUSY ; $j++) { $x = $x + $j }
        return;
    }
    select(undef, undef, undef, 0.001);
}

sub wr {
    my ($s) = @_;
    my $o   = 0;
    my $n   = length($s);
    while ($o < $n) {
        my $w = syswrite(TTY, $s, $CHUNK, $o);
        if (!defined $w) { next if $! == POSIX::EINTR(); return 0 }
        $o += $w;
        pace();
    }
    return 1;
}

# The checksum covers the framing too — "<id> <verb> <payload>" — so a mangled
# id or verb is a checksum failure the client can act on, not a line it drops.
sub reply {
    my ($id, $verb, $payload) = @_;
    $payload = "" unless defined $payload;
    wr("$id $verb " . sum16("$id $verb $payload") . " " . $payload . "\n");
}

# ---- request handling -------------------------------------------------------
# Returns ($id, $verb, $payload) for a well-formed, checksum-clean request;
# ($id, "", "") when the line must be NAKed (the id is the one we could read, or
# 0); and () for a line that is not a request at all.
sub parse_request {
    my ($line) = @_;
    return () unless defined $line && $line ne "";
    my ($id, $verb, $sum, $payload) = split(/ /, $line, 4);
    $payload = "" unless defined $payload;
    my $nakid = (defined($id) && $id =~ /^\d+$/) ? $id : 0;
    return ($nakid, "", "") unless defined $verb && $verb =~ /^[A-Z]+$/;
    return ($nakid, "", "") unless defined $sum && $sum =~ /^[0-9a-fA-F]{4}$/;
    return ($nakid, "", "") unless lc($sum) eq sum16("$id $verb $payload");
    return ($id, $verb, $payload);
}

sub parse_opts {
    my ($s) = @_;
    my %o = (t => 0, o => $OUTMAX, p => "idle", d => 0);
    return \%o if $s eq "-";
    my $kv;
    foreach $kv (split(/,/, $s)) {
        next unless $kv =~ /^([a-z])=(.*)$/;
        $o{$1} = $2;
    }
    return \%o;
}

# Everything a command inherits is set here, in the child, so the agent's own
# tty can never leak into it: stdin is /dev/null and stdout/stderr are a file.
# A PIPE would be the obvious choice and is the wrong one — a backgrounded
# grandchild (`netscape &`) holds the write end open and the read never returns,
# which wedges the whole channel.
sub spawn {
    my ($cmd, $path) = @_;
    my $pid = fork();
    return undef unless defined $pid;
    return $pid if $pid;
    setsid();    # own process group, so a timeout can kill the whole tree
    close(TTY);
    open(STDIN,  "</dev/null");
    open(STDOUT, ">$path") or POSIX::_exit(253);
    open(STDERR, ">&STDOUT");
    exec("/bin/sh", "-c", $cmd);
    POSIX::_exit(252);
}

# Answer control traffic that arrives while we are talking. Returns 1 if the
# host aborted this reply. Without this an ABORT is not even LOOKED at until the
# whole capped output has been paced onto a ~140 B/s wire, so a client that
# times out on a big reply leaves a backlog that eats the next client's PING.
sub poll_control {
    my ($id) = @_;
    my ($aid, $averb, $apay) = parse_request(read_line(2));
    return 0 unless defined $aid;
    if ($averb eq "") { reply($aid, "N", esc("bad request checksum")); return 0 }
    if ($averb eq "ABORT") {
        return 0 unless $apay eq "" || $apay eq $id;
        reply($aid, "P", "$PROTO $VERSION $SRCSUM");
        $ABORTED = 1;
        return 1;
    }
    if ($averb eq "PING") { reply($aid, "P", "$PROTO $VERSION $SRCSUM"); return 0 }
    if ($averb eq "RESULT") {
        # A client that saw a corrupted line asks for a replay WHILE the reply
        # it corrupted is still going out. Stop this emission and start the
        # remembered reply again under the requester's id — if it is only read
        # after the current one has finished draining, the client is waiting on
        # a wire it cannot get a word in on.
        my $t = (split(/ /, $apay, 2))[0];
        $t = "" unless defined $t;
        if ($t ne "" && $t eq $LAST_ID) { $REPLAY_TO = $aid; $ABORTED = 1; return 1 }
        reply($aid, "E", esc("no remembered result for '$t'"));
    }
    return 0;
}

# Emit a file as O lines, at most $max raw bytes. Returns the number of bytes
# left unsent. Sets $ABORTED and stops early if the host says stop.
sub send_output {
    my ($id, $path, $max) = @_;
    my $size = (stat($path))[7];
    $size = 0 unless defined $size;
    return 0 if $size == 0;
    open(OUT, "<$path") or return 0;
    binmode(OUT);
    my $sent = 0;
    my $buf;
    while ($sent < $max) {
        my $want = $max - $sent;
        $want = $LINEMAX if $want > $LINEMAX;
        my $got = read(OUT, $buf, $want);
        last unless $got;
        reply($id, "O", esc($buf));
        $sent += $got;
        last if poll_control($id);
    }
    close(OUT);
    return $size > $sent ? $size - $sent : 0;
}

sub do_run {
    my ($id, $opts, $cmd, $cmdsum) = @_;
    my $path = "$LOGDIR/irixexec-$id.out";
    unlink($LAST_PATH) if $LAST_PATH ne "" && $LAST_PATH ne $path;
    unlink($path);
    $LAST_ID  = "";
    $LAST_CMD = "";
    $BUSY = ($opts->{p} eq "fast") ? $BUSY_FAST : 0;

    my $pid = spawn($cmd, $path);
    if (!defined $pid) { reply($id, "E", esc("fork failed: $!")); return }

    if ($opts->{d}) {
        # Detached: the caller gets the pid and the log path, now. Reaping is
        # left to the main loop's WNOHANG sweep so nothing zombies.
        my $note = "detached pid $pid, output -> $path\n";
        reply($id, "O", esc($note));
        # Remembered so a corrupted reply is replayable — with no output, since
        # the detached command's log is still being written to.
        $LAST_ID     = $id;
        $LAST_CMD    = $cmdsum;
        $LAST_PATH   = "";
        $LAST_MAX    = 0;
        $LAST_STATUS = 0;
        reply($id, "X", 0);
        return;
    }

    my $deadline = $opts->{t} > 0 ? time() + $opts->{t} : 0;
    my $status   = 0;
    my $killed   = 0;
    my $killed_at = 0;
    while (1) {
        my $r = waitpid($pid, WNOHANG);
        last if $r == $pid || $r == -1;
        # Stay answerable while the command runs: ABORT has to reach us, and a
        # poll every 250 ms is free next to what the command is doing.
        my ($aid, $averb, $apay) = parse_request(read_line(1));
        if (defined $aid) {
            if ($averb eq "") { reply($aid, "N", esc("bad request checksum")) }
            elsif ($averb eq "ABORT") {
                # The target id is CHECKED. An ABORT left in the buffer by a
                # previous client naming a previous run must not kill this one.
                if ($apay eq "" || $apay eq $id) {
                    kill(-15, $pid);
                    $killed    = 258;
                    $killed_at = time();
                }
                reply($aid, "P", "$PROTO $VERSION $SRCSUM");
            }
            elsif ($averb eq "PING") { reply($aid, "P", "$PROTO $VERSION $SRCSUM") }
            elsif ($aid ne $id) { reply($aid, "E", esc("busy running $id")) }
        }
        if (!$killed && $deadline && time() > $deadline) {
            kill(-15, $pid);
            $killed    = 257;
            $killed_at = time();
        }
        # SIGTERM is a request; SIGKILL is not. Anything still alive 3 s after
        # the request stops being asked nicely, or a wedged command would hold
        # the channel for ever.
        if ($killed && $killed_at && time() > $killed_at + 3) {
            kill(-9, $pid);
            $killed_at = 0;
        }
    }
    $status = $?;

    my $code;
    if    ($killed)       { $code = $killed }
    elsif ($status & 127) { $code = 256 + ($status & 127) }
    else                  { $code = ($status >> 8) & 255 }
    # sprintf, not interpolation: this perl (5.004, IRIX n32) was caught
    # rendering the integer 265 as the string "3,5" — intermittently, roughly
    # 1 run in 5, and CONSISTENTLY, i.e. the checksum was computed over the
    # garbled text too, so the wire's integrity check could not see it. Forcing
    # the value to a string once, here, keeps a single rendering out of the hot
    # path. The client also recovers by replay if it ever happens again.
    $code = sprintf("%d", $code);

    # Remembered so a client that reads a corrupted line can ask for the whole
    # reply again instead of re-running a command that may not be repeatable.
    # The output file outlives the reply for exactly that reason; the NEXT run
    # is what removes it.
    $LAST_ID     = $id;
    $LAST_CMD    = $cmdsum;
    $LAST_PATH   = $path;
    $LAST_MAX    = $opts->{o};
    $LAST_STATUS = $code;
    emit_result($id);
}

# $id is the id the reply goes out under — the ORIGINAL run's id the first time,
# and the RESULT REQUEST's id on a replay, so the client can tell a replay from
# the tail of the original reply that is still on the wire.
sub emit_result {
    my ($id) = @_;
    while (1) {
        $ABORTED   = 0;
        $REPLAY_TO = "";
        my $dropped = send_output($id, $LAST_PATH, $LAST_MAX);
        if ($REPLAY_TO ne "") { $id = $REPLAY_TO; next }
        if ($ABORTED) { reply($id, "X", 258); return }
        reply($id, "T", "$dropped " . esc($LAST_PATH)) if $dropped;
        reply($id, "X", $LAST_STATUS);
        return;
    }
}

# ---- main loop --------------------------------------------------------------
$RBUF    = "";
$DISCARD = 0;

# One protocol line. read_line(0) blocks — that is how the agent idles, asleep
# in the kernel at zero emulated CPU. read_line(1) polls for at most 250 ms and
# returns undef if no COMPLETE line arrived, which is what keeps a half-written
# line from wedging the agent while a command is running. read_line(2) does not
# wait at all: it is the mid-transmission ABORT poll.
# Lines longer than 64 KB are a desynchronised host, not a request: the buffer
# is dropped AND the rest of that line is discarded up to the next LF, so its
# tail can never parse as a fresh request of its own.
sub read_line {
    my ($nb) = @_;
    while (1) {
        my $i = index($RBUF, "\n");
        if ($i >= 0) {
            my $line = substr($RBUF, 0, $i);
            $RBUF = substr($RBUF, $i + 1);
            if ($DISCARD) { $DISCARD = 0; next }
            # CRs are stripped (a host that sends CRLF still parses), but
            # NOTHING else: the escaped command is the last field and its own
            # leading and trailing spaces are data.
            $line =~ s/\r//g;
            return $line if $line ne "";
            next;
        }
        if (length($RBUF) > 65536) { $RBUF = ""; $DISCARD = 1 }
        if ($nb) {
            my $rin = "";
            vec($rin, fileno(TTY), 1) = 1;
            return undef unless select($rin, undef, undef, $nb == 2 ? 0 : 0.25) > 0;
        }
        my $buf;
        my $n = sysread(TTY, $buf, 256);
        if (!defined $n) { next if $! == POSIX::EINTR(); return undef }
        return undef if $n == 0;
        $RBUF .= $buf;
    }
}

# Declining is a 60-second sleep and a clean exit, not a fast one: init disables
# a respawn entry that restarts ~10 times in ~2 minutes.
if (!claim_line()) {
    sleep(60);
    exit 0;
}
$SRCSUM = source_sum();
sweep_outputs();
open_line();
while (1) {
    my $line = read_line(0);
    last unless defined $line;
    1 while waitpid(-1, WNOHANG) > 0;    # reap detached children
    my ($id, $verb, $payload) = parse_request($line);
    next unless defined $id;
    if ($verb eq "") { reply($id, "N", esc("bad request checksum")); next }
    if ($verb eq "PING" || $verb eq "ABORT") {
        reply($id, "P", "$PROTO $VERSION $SRCSUM");
        next;
    }
    if ($verb eq "RESULT") {
        my $target = (split(/ /, $payload, 2))[0];
        $target = "" unless defined $target;
        if ($target ne "" && $target eq $LAST_ID) { emit_result($id) }
        else { reply($id, "E", esc("no remembered result for '$target'")) }
        next;
    }
    if ($verb ne "RUN") { reply($id, "N", esc("unknown verb '$verb'")); next }
    my ($optstr, $esccmd) = split(/ /, $payload, 2);
    $esccmd = "" unless defined $esccmd;
    # A re-sent RUN (the client's answer to a NAK) must never run twice. Same id
    # AND same command = the same request; replay what it produced.
    if ($LAST_ID ne "" && $id eq $LAST_ID && sum16($esccmd) eq $LAST_CMD) {
        emit_result($id);
        next;
    }
    my $cmd = unesc($esccmd);
    if (!defined $cmd) { reply($id, "N", esc("bad escape in command")); next }
    if ($cmd eq "")    { reply($id, "X", 0);                            next }
    do_run($id, parse_opts(defined($optstr) ? $optstr : "-"), $cmd, sum16($esccmd));
}
exit 0;
