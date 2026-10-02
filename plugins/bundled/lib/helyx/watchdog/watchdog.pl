use POSIX ":sys_wait_h";
use Fcntl;
my $nonce = shift @ARGV;
sub fail { syswrite(STDOUT, "$nonce 0\n$_[0]: $!"); exit 0 }
my $feed = shift @ARGV;
my $dir = shift @ARGV;
my $grace = shift(@ARGV) / 1000;
my $cap = shift @ARGV;
for (keys %ENV) { $ENV{$1} = substr(delete $ENV{$_}, 1) if /^HELYX_KEEP_(PERL.*)/s }
chdir($dir) or fail("cannot enter the working directory $dir");
pipe(my $r, my $w) or fail("pipe failed");
pipe(my $er, my $ew) or fail("report pipe failed");
my ($ir, $iw);
if ($feed != -1) { pipe($ir, $iw) or fail("input pipe failed") }
my $child = fork() // fail("fork failed");
if ($child == 0) {
  close($w); close($er); close($iw) if $iw;
  setpgrp(0, 0);
  eval {
    sysread($r, my $go, 1) or exit 0;
    if ($ir) { open(STDIN, "<&", $ir) } else { open(STDIN, "<", "/dev/null") }
    syswrite(STDOUT, "$nonce 1\n");
    exec @ARGV;
    die "cannot run $ARGV[0]: $!\n";
  };
  syswrite($ew, $@);
  exit 0;
}
$SIG{TERM} = "IGNORE";
$SIG{PIPE} = "IGNORE";
close($r); close($ew); close($ir) if $ir;
syswrite(STDOUT, "$nonce $child\n");
my $go = ""; my $c = "";
while (sysread(STDIN, $c, 1)) { last if $c eq "\n"; $go .= $c }
if ($c eq "\n") { syswrite($w, "g"); close($w) }
else { close($w); kill("KILL", -$child); waitpid($child, 0); exit 0 }
fcntl($iw, F_SETFL, O_NONBLOCK) if $iw;
sub stop {
  kill("TERM", -$child);
  my $t = 0; my $done;
  until (($done = waitpid($child, WNOHANG) > 0) or $t >= $grace) { select(undef, undef, undef, 0.05); $t += 0.05 }
  my $s = $?;
  kill("KILL", -$child);
  if (!$done) { waitpid($child, 0); $s = $? }
  $s
}
sub finish {
  if (sysread($er, my $err, 4096)) { syswrite(STDOUT, "$go 0\n$err"); exit 0 }
  exit(($_[0] & 127) ? 128 + ($_[0] & 127) : $_[0] >> 8);
}
my $out = "";
while (1) {
  if ($iw and $feed == 0 and !length($out)) { close($iw); undef $iw }
  my $rin = ""; vec($rin, fileno(STDIN), 1) = 1;
  my $win; if ($iw and length($out)) { $win = ""; vec($win, fileno($iw), 1) = 1 }
  my $n = select(my $rout = $rin, $win, undef, 0.05);
  if ($n > 0 and vec($rout, fileno(STDIN), 1)) {
    my $got = sysread(STDIN, my $buf, 65536);
    if (!$got) { stop(); exit 0 }
    if ($iw and $feed < 0) {
      my $end = index($buf, "\0");
      if ($end < 0) { $out .= $buf } else { $out .= substr($buf, 0, $end); $feed = 0 }
      if (length($out) > $cap) { finish(stop()) }
    }
  }
  if ($n > 0 and $win and vec($win, fileno($iw), 1)) {
    my $put = syswrite($iw, $out);
    if (defined($put)) { substr($out, 0, $put) = "" } elsif (!$!{EAGAIN}) { $out = ""; $feed = 0 }
  }
  finish($?) if waitpid($child, WNOHANG) > 0;
}
