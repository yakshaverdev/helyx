defmodule Helyx.HarnessIO.PathTest do
  # The lookup of the harness program and of perl on PATH. PATH is global,
  # so this module is not async; the provider tests run async because only
  # these tests change PATH.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.Provider.{ClaudeCode, Codex}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Helyx.Test.Hands.fake()
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    for program <- ["claude", "codex"] do
      File.write!(Path.join(bin, program), "#!/bin/sh\n")
      File.chmod!(Path.join(bin, program), 0o755)
    end

    found = %{kill: System.find_executable("kill"), sleep: System.find_executable("sleep")}
    path = System.get_env("PATH")
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)
    %{bin: bin, work: tmp, found: found}
  end

  defp perl(bin, script) do
    File.write!(Path.join(bin, "perl"), "#!/bin/sh\n" <> script)
    File.chmod!(Path.join(bin, "perl"), 0o755)
  end

  test "with no perl on PATH, the start of claude returns an error that names perl",
       %{work: work} do
    assert {:error, "perl not found" <> _} = ClaudeCode.init("m", [], cwd: work)
  end

  test "with no perl on PATH, the connect of codex returns an error that names perl",
       %{work: work} do
    assert {:error, "perl not found" <> _} = Codex.init("m", [], cwd: work)
  end

  test "a perl that ends with no output fails the connect with an error that names perl",
       %{bin: bin, work: work, found: found} do
    perl(bin, "exit 1\n")
    File.ln_s!(found.kill, Path.join(bin, "kill"))

    assert {:error, {:not_started, "the perl watchdog gave no marker: "}} =
             Codex.init("m", [], cwd: work)

    # The watchdog exited, so the start dropped its hold (#802).
    assert Helyx.Test.Hands.held() == []
  end

  test "a watchdog that is not gone by the deadline keeps its hold and is not signalled",
       %{bin: bin, work: work, found: found} do
    # Output over the preamble limit with no marker, then a program that
    # does not end at the close: a write after the close does not end it.
    perl(bin, "trap '' PIPE\nprintf '%5000s' x\nexec #{found.sleep} 30\n")
    File.ln_s!(found.kill, Path.join(bin, "kill"))

    assert {:error, {:not_started, "the perl watchdog gave no marker: " <> _}} =
             Codex.init("m", [], cwd: work)

    assert [watchdog: group] = Helyx.Test.Hands.held()
    assert os_alive?("-#{group}")
    signal_group("KILL", group)
  end

  # `Helyx.Watchdog.start/4` drops the invalid byte, so the error is
  # valid UTF-8 for every reader, the model too.
  test "a perl that writes an invalid byte and ends gives valid text that names perl",
       %{bin: bin, work: work} do
    perl(bin, "printf 'bad \\351 byte'\nexit 1\n")

    assert {:error, {:not_started, "the perl watchdog gave no marker: bad  byte"}} =
             Codex.init("m", [], cwd: work)

    # No kill(1) on PATH confirms nothing, so the hold stays for the hands.
    assert [watchdog: _] = Helyx.Test.Hands.held()
  end
end
