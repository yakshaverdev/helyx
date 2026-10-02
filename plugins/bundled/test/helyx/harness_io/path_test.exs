defmodule Helyx.HarnessIO.PathTest do
  # The lookup of the harness program and of perl on PATH. PATH is global,
  # so this module is not async; the provider tests run async because only
  # these tests change PATH.
  use ExUnit.Case, async: false

  alias Helyx.Provider.{ClaudeCode, Codex}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    for program <- ["claude", "codex"] do
      File.write!(Path.join(bin, program), "#!/bin/sh\n")
      File.chmod!(Path.join(bin, program), 0o755)
    end

    path = System.get_env("PATH")
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)
    %{bin: bin, work: tmp}
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
       %{bin: bin, work: work} do
    perl(bin, "exit 1\n")

    assert {:error, {:not_started, "the perl watchdog gave no marker: "}} =
             Codex.init("m", [], cwd: work)
  end

  # `Helyx.HarnessIO.cap_error/1` drops the invalid byte, so the error is
  # valid UTF-8 for every reader, the model too.
  test "a perl that writes an invalid byte and ends gives valid text that names perl",
       %{bin: bin, work: work} do
    perl(bin, "printf 'bad \\351 byte'\nexit 1\n")

    assert {:error, {:not_started, "the perl watchdog gave no marker: bad  byte"}} =
             Codex.init("m", [], cwd: work)
  end
end
