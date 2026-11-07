use POSIX qw(:sys_wait_h :signal_h);
use Fcntl;
my $max = shift @ARGV;
pipe(my $or, my $ow) or exit 125;
pipe(my $er, my $ew) or exit 125;
my $held = POSIX::SigSet->new(SIGTERM, SIGHUP);
sigprocmask(SIG_BLOCK, $held);
my $child = fork() // exit 125;
if ($child == 0) {
  sigprocmask(SIG_UNBLOCK, $held);
  close($or); close($er);
  open(STDOUT, ">&", $ow) or exit 125;
  open(STDERR, ">&", $ew) or exit 125;
  close($ow); close($ew);
  exec(@ARGV) or exit 127;
}
# Read before the IGNORE below, which discards a pending signal.
my $pending = POSIX::SigSet->new;
sigpending($pending);
$SIG{TERM} = "IGNORE";
$SIG{HUP} = "IGNORE";
$SIG{PIPE} = "IGNORE";
sigprocmask(SIG_UNBLOCK, $held);
for my $sig (SIGTERM, SIGHUP) { kill($sig, $child) if $pending->ismember($sig) }
close($ow); close($ew);
binmode(STDOUT);
my %open = (o => $or, e => $er);
my $gone = 0;
fcntl($_, F_SETFL, O_NONBLOCK) for values %open;
sub put {
  my $d = pack("a1 N", $_[0], length($_[1])) . $_[1];
  while (length($d) and !$gone) {
    my $w = syswrite(STDOUT, $d);
    if (defined($w)) { substr($d, 0, $w) = "" } else { $gone = 1 }
  }
}
sub drain {
  my ($tag) = @_;
  for (1 .. 16) {
    my $n = sysread($open{$tag}, my $buf, $max);
    if (!defined($n)) { return if $!{EAGAIN}; delete $open{$tag}; return }
    if ($n == 0) { delete $open{$tag}; return }
    put($tag, $buf);
  }
}
while (1) {
  my $rin = "";
  vec($rin, fileno($open{$_}), 1) = 1 for keys %open;
  select(my $rout = $rin, undef, undef, 0.05);
  drain($_) for keys %open;
  if (waitpid($child, WNOHANG) > 0) {
    my $s = $?;
    drain($_) for keys %open;
    exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  }
}
