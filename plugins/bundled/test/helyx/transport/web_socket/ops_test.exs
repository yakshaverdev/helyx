defmodule Helyx.Transport.WebSocket.OpsTest do
  use ExUnit.Case, async: true

  # A VM with the two ebins of Helyx and nothing else loaded: the atom of a
  # wire param that only a session module names does not exist there. A
  # conversion with `String.to_existing_atom/1` made the key the business of
  # whichever module the VM had loaded, and in the fresh VM of a print run the
  # connection process died on `:answers` before the session server loaded a
  # module that holds it (2026-11-11): the client got "no connection to the
  # server", and no turn ran.
  #
  # The script names no atom of a param and builds no struct, and it reaches
  # the transport through `apply/3`: a direct call makes the compiler load
  # the module to check it, which puts the atom in the VM before the premise.
  @subscribe """
  # The premise: the VM holds no `:answers` before the call.
  false =
    try do
      :erlang.binary_to_existing_atom("answers")
      true
    rescue
      _ -> false
    end

  params = %{"session" => "abc", "answers" => true, "tail" => 5}

  {:ok, _session, opts} =
    apply(Helyx.Transport.WebSocket.Ops, :subscribe_params, [Helyx.Core, params])

  {_, true} = Enum.find(opts, fn {key, _} -> Atom.to_string(key) == "answers" end)
  {_, 5} = Enum.find(opts, fn {key, _} -> Atom.to_string(key) == "tail" end)

  IO.puts("ok")
  """

  # A VM boot, about a second, and the atoms of a fresh VM are the point.
  @tag :slow
  test "the options of a subscribe are atoms that the transport names" do
    paths = Enum.flat_map([:helyx_plugins, :helyx], &["-pa", Application.app_dir(&1, "ebin")])

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, paths ++ ["-e", @subscribe]}
      ])

    assert await_exit(port, "") =~ ~r/\Aok\n\z/
  end

  # The output of the VM, or a failure that shows what it wrote first.
  defp await_exit(port, out) do
    receive do
      {^port, {:data, data}} -> await_exit(port, out <> data)
      {^port, {:exit_status, 0}} -> out
      {^port, {:exit_status, status}} -> flunk("the VM ended with #{status}:\n#{out}")
    end
  end
end
