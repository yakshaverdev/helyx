defmodule Helyx.Session.LockPerlTest do
  # The bounds of the folder lock take (docs/features/session-lock.md,
  # "Bounds"), with a `perl` of the test first on PATH. PATH is global to the
  # VM, so the module is not async: ExUnit runs it after the async modules.
  use ExUnit.Case, async: false

  import Helyx.Test.Events

  alias Helyx.Session

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @plugins [Helyx.Test.Provider]

  # A start that fails ends the supervisor it linked, and the caller gets
  # that exit.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup %{tmp_dir: dir} do
    real = System.find_executable("perl")
    path = System.get_env("PATH")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)
    %{bin: bin, real: real, path: path, sessions: Path.join(dir, "sessions")}
  end

  defp fake_perl(bin, script) do
    file = Path.join(bin, "perl")
    File.write!(file, "#!/bin/sh\n" <> script)
    File.chmod!(file, 0o755)
  end

  defp start_link(sessions) do
    core = :"core_#{System.unique_integer([:positive])}"
    Helyx.Core.start_link(name: core, plugins: @plugins, sessions_dir: sessions)
  end

  defp start_supervised_core(sessions) do
    core = :"core_#{System.unique_integer([:positive])}"

    start_supervised!({Helyx.Core, name: core, plugins: @plugins, sessions_dir: sessions},
      id: core
    )

    core
  end

  defp written(sessions), do: Path.wildcard(Path.join([sessions, "*", "*.jsonl"]))

  test "no perl on PATH fails the start and writes nothing", ctx do
    assert {:error, {:lock_failed, "perl is not on the PATH" <> _}} =
             start_link(ctx.sessions)

    assert written(ctx.sessions) == []
  end

  test "a perl that ends with no answer fails the start with its output", ctx do
    fake_perl(ctx.bin, "echo broken\nexit 3\n")

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl ended with no answer: broken\n"}}

    assert written(ctx.sessions) == []
  end

  test "output that is not UTF-8 is dropped from the reason", ctx do
    # The first byte of a two-byte character, then the end.
    fake_perl(ctx.bin, "printf 'a\\303'\nexit 3\n")

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl ended with no answer: a"}}
  end

  test "a CRLF line end reads as a newline, also in the answer line", ctx do
    fake_perl(ctx.bin, "printf 'broken\\r\\n'\nexit 3\n")

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl ended with no answer: broken\n"}}

    # The nonce is the fourth argument: `-e`, the program, `--`, the nonce.
    fake_perl(ctx.bin, "printf '%s ok\\r\\n' \"$4\"\nread x\n")
    core = start_supervised_core(ctx.sessions)
    assert {:ok, _session} = Session.start(core, model: "test/ok", sessions_dir: ctx.sessions)
  end

  test "output before the answer is read past up to the bound", ctx do
    # The answer line is "<16 hex> ok", 19 bytes. Under the bound: the
    # output and the answer line hold 4095 bytes.
    fake_perl(ctx.bin, "printf '%04075d\\n' 0\nexec #{ctx.real} \"$@\"\n")
    core = start_supervised_core(ctx.sessions)
    assert {:ok, _session} = Session.start(core, model: "test/ok", sessions_dir: ctx.sessions)
  end

  test "output before the answer over the bound fails the start", ctx do
    # At the bound: the output and the answer line hold 4096 bytes.
    fake_perl(ctx.bin, "printf '%04076d\\n' 0\nexec #{ctx.real} \"$@\"\n")

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl wrote 4096 bytes with no answer in them"}}

    assert written(ctx.sessions) == []
  end

  test "output with no newline over the bound fails the start", ctx do
    fake_perl(ctx.bin, "printf '%05000d' 0\nread x\n")

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl wrote 4096 bytes with no answer in them"}}
  end

  @tag :slow
  test "a perl with no answer in 5000 ms fails the start", ctx do
    fake_perl(ctx.bin, "read x\n")
    started = System.monotonic_time(:millisecond)

    assert start_link(ctx.sessions) ==
             {:error, {:lock_failed, "perl gave no answer in 5000 ms"}}

    assert System.monotonic_time(:millisecond) - started >= 5000
    assert written(ctx.sessions) == []
  end

  # One perl for each Core, not for each session: a session with a file
  # starts with no perl on PATH.
  test "a session of the Core starts no perl", ctx do
    System.put_env("PATH", ctx.path)
    core = start_supervised_core(ctx.sessions)
    System.put_env("PATH", ctx.bin)

    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: ctx.sessions)
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "hello")
    collect_until(:turn_end)

    assert [path] = written(ctx.sessions)
    assert File.read!(path) =~ "hello"
  end
end
