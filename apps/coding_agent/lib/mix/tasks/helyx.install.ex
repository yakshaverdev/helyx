defmodule Mix.Tasks.Helyx.Install do
  @shortdoc "Builds the helyx release and installs it"
  @moduledoc """
  Builds the `helyx` release of the current checkout and installs it, so
  that `helyx` starts the coding agent in any folder.

      mix helyx.install [--prefix DIR] [--bin-dir DIR]

  The build goes to `<prefix>/releases/<commit>` (default prefix
  `~/.helyx`), `<prefix>/current` points at it, and `<bin-dir>/helyx`
  (default `~/.local/bin`) starts it. An existing build folder is never
  replaced.
  The install keeps the build that `current` pointed at before and deletes
  the older ones. The task runs in `prod`. The design is in
  `docs/features/local-release.md`.
  """

  use Mix.Task

  @usage "usage: mix helyx.install [--prefix DIR] [--bin-dir DIR]"
  # The ticks of the launcher of `serve` after a signal, one SIGTERM each
  # second; a boot under load ends well within them.
  @term_tries 20

  # The supervisor of `helyx serve`, run as the launcher itself. Before the
  # fork it catches every signal whose default ends a process, by the names
  # of its OS: all but the ones that are ignored or stop (and IO on macOS,
  # where it is ignored) and the fault signals, whose real delivery a
  # handler would make repeat. A signal that was ignored at its start, as
  # under `nohup`, stays ignored by it. A handler only counts.
  # The VM gets its pid from the fork, a group of its own, and the command.
  # The loop wakes each 0.25 s, or at a signal: each new signal sends the VM
  # SIGTERM, and then one tick each second sends SIGTERM again while it
  # lives, at most `@term_tries` ticks, since a VM drops a SIGTERM that comes
  # before its handler. `waitpid` gives the status of the VM, and the
  # supervisor exits with it at once, so it sends nothing to a pid after its
  # reap. The text has no single quote: it goes in one of the launcher.
  @serve """
  use Config; use POSIX (); use Time::HiRes (); my $stop = 0;
  my %skip = map { $_ => 1 } qw(ZERO KILL STOP CHLD CLD CONT TSTP TTIN TTOU URG WINCH INFO NUM32 NUM33
    ILL TRAP ABRT IOT BUS FPE SEGV SYS EMT);
  @skip{qw(IO POLL)} = (1, 1) if $^O eq "darwin";
  my $count = sub { $stop++ };
  for my $name (split " ", $Config{sig_name}) {
    $SIG{$name} = $count unless $skip{$name} or ($SIG{$name} // "") eq "IGNORE";
  }
  my $pid = fork;
  defined $pid or die "helyx: fork: $!\\n";
  if (!$pid) {
    setpgrp(0, 0);
    exec { $ARGV[0] } @ARGV or die "helyx: $ARGV[0]: $!\\n";
  }
  my ($sent, $ticks, $next) = (0, 0, 0);
  while (1) {
    if (waitpid($pid, POSIX::WNOHANG()) == $pid) {
      exit(POSIX::WIFEXITED($?) ? POSIX::WEXITSTATUS($?) : 128 + POSIX::WTERMSIG($?));
    }
    my $now = Time::HiRes::time();
    if ($stop > $sent) {
      ($sent, $next) = ($stop, $now + 1);
      kill "TERM", $pid;
    } elsif ($stop && $ticks < #{@term_tries} && $now >= $next) {
      ($ticks, $next) = ($ticks + 1, $now + 1);
      kill "TERM", $pid;
    }
    Time::HiRes::sleep(0.25);
  }
  """

  @impl true
  def run(argv) do
    opts = parse(argv)
    prefix = Path.expand(opts[:prefix] || "~/.helyx")
    releases = Path.join(prefix, "releases")
    File.mkdir_p!(releases)
    # The OS pid keeps the folder of one install apart from another's.
    build = Path.join(releases, ".build-#{System.pid()}")

    try do
      Mix.Task.run("release", ["helyx", "--path", build, "--quiet"])
      install(build, prefix, Path.expand(opts[:bin_dir] || "~/.local/bin"))
    after
      File.rm_rf!(build)
    end
  end

  @doc false
  # Moves the release in `build` into place. Public so that a test installs
  # a fake build without a release build.
  @spec install(Path.t(), Path.t(), Path.t()) :: :ok
  def install(build, prefix, bin_dir) do
    releases = Path.join(prefix, "releases")
    current = Path.join(prefix, "current")
    previous = previous(current)

    [_erts, version] =
      build |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    [_app_version, commit] = String.split(version, "+", parts: 2)
    name = free_name(releases, commit, 1)
    File.rename!(build, Path.join(releases, name))
    # The launcher names `current`, not the build, so it is written before
    # the swap.
    write_launcher(Path.join(current, "bin/helyx"), bin_dir)

    # A rename over the old link, so a start finds the old or the new build.
    link = Path.join(releases, ".current-#{System.pid()}")
    _ = File.rm(link)
    File.ln_s!(Path.join("releases", name), link)
    File.rename!(link, current)
    Mix.shell().info("installed #{version} in #{Path.join(releases, name)}")

    # The swap is the commit point: a raise before it leaves `current` and
    # the kept builds as they were. A deletion after it only warns, and the
    # next install tries again; a listing that fails raises.
    for entry <- File.ls!(releases), entry not in [name, previous] do
      with {:error, reason, file} <- File.rm_rf(Path.join(releases, entry)) do
        Mix.shell().error("could not delete #{file}: #{:file.format_error(reason)}")
      end
    end

    :ok
  end

  # The command line is a boundary. The usage text shows no argument, so no
  # argument needs escaping.
  defp parse(argv) do
    case OptionParser.parse(argv, strict: [prefix: :string, bin_dir: :string]) do
      {opts, [], []} -> opts
      _ -> Mix.raise(@usage)
    end
  rescue
    # OptionParser raises on "-=" and on a switch that is not UTF-8.
    _ in [ArgumentError, UnicodeConversionError] -> Mix.raise(@usage)
  end

  # No `current` is the first install. Any other error fails the `case`.
  defp previous(current) do
    case File.read_link(current) do
      {:ok, target} -> Path.basename(target)
      {:error, :enoent} -> nil
    end
  end

  defp free_name(releases, commit, k) do
    name = if k == 1, do: commit, else: "#{commit}-#{k}"

    case File.lstat(Path.join(releases, name)) do
      {:error, :enoent} -> name
      _ -> free_name(releases, commit, k + 1)
    end
  end

  # The launcher keeps the folder and the arguments of the user, and adds no
  # retry. The release script resolves `current` once, at start. `bin_dir`
  # is an absolute path.
  defp write_launcher(script, bin_dir) do
    File.mkdir_p!(bin_dir)
    launcher = Path.join(bin_dir, "helyx")
    # One fixed name: the next install replaces a file that a failed one left.
    tmp = Path.join(bin_dir, ".helyx-install")

    command = "#{sh_quote(script)} eval 'System.halt(CodingAgent.CLI.main(System.argv()))' \"$@\""

    # `serve` runs under a perl supervisor (`@serve`), with the VM in a
    # process group of its own, so the SIGINT of a terminal reaches only the
    # supervisor: the VM cannot handle SIGINT (docs/features/serve.md). Any
    # other command gets the path of the launcher, which starts a server
    # with it (docs/features/tui-attach.md, decision 10).
    File.write!(tmp, """
    #!/bin/sh
    if [ "$1" = serve ]; then
      exec perl -e '#{@serve}' -- #{command} </dev/null
    fi
    HELYX_LAUNCHER=#{sh_quote(launcher)}
    export HELYX_LAUNCHER
    exec #{command}
    """)

    File.chmod!(tmp, 0o755)
    File.rename!(tmp, launcher)
  end

  defp sh_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"
end
