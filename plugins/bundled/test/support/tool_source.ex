defmodule Helyx.Test.ToolSource do
  @moduledoc false
  # A tool source that the test drives: its source process tells the
  # observer of its Core that it runs, then runs each function that the
  # test sends it and answers with the result. A call of one of its tools
  # answers with the called name.
  @behaviour Helyx.Tool

  import ExUnit.Assertions

  @doc "Makes the test process the observer of the sources of `core`."
  def observe(core) do
    :persistent_term.put({__MODULE__, core}, self())
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, core}) end)
  end

  @doc "Runs `fun` in the source process `source` and gives its result."
  def in_source(source, fun) do
    send(source, {:do, self(), fun})
    assert_receive {:done, ^source, result}
    result
  end

  @doc "A deferred entry of `name` with `overrides`."
  def entry(name, overrides \\ %{}) do
    Map.merge(
      %{name: name, description: "d", parameters: %{"type" => "object"}, exposure: :deferred},
      overrides
    )
  end

  @impl true
  def source(info) do
    observer = :persistent_term.get({__MODULE__, info.core})
    send(observer, {:source_up, self()})
    loop()
  end

  defp loop do
    receive do
      {:do, from, fun} ->
        send(from, {:done, self(), fun.()})
        loop()

      {:EXIT, _pid, _reason} ->
        :ok
    end
  end

  @impl true
  def run(_args, _cwd), do: {:ok, "ran #{Helyx.Tool.context().tool}"}
end

defmodule Helyx.Test.ToolSource.Silent do
  @moduledoc false
  # A tool source that never names its groups, so it stays pending.
  @behaviour Helyx.Tool

  @impl true
  def source(_info), do: receive(do: ({:EXIT, _pid, _reason} -> :ok))

  @impl true
  def run(_args, _cwd), do: {:ok, ""}
end
