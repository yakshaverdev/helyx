defmodule Helyx.Test.Hook do
  @moduledoc false
  # Test hook plugins (docs/features/hooks.md). Each one runs the function
  # that a test set for its point and its Core (`script/3`), with the call
  # input, and sends `{:hook, module, point, input}` to the process
  # registered as `<core>.Test` first. A point with no function allows,
  # keeps, or settles. `release/3` sends `{:released, module, handles,
  # mode}` to the pid of each handle `{pid, tag}`, and confirms every
  # handle whose tag is not `:stuck`. The option `points:` gives the
  # points of the hook, `before_tool` and `after_tool` by default.

  @defaults %{before_tool: :allow, after_tool: :keep, before_settle: :settle}

  # Sets `fun` for `module` at `point` in the Core `core`.
  def script(core, module, point, fun), do: :persistent_term.put({module, core, point}, fun)

  def test_name(core), do: Module.concat(core, Test)

  # Registers as `<core>.Test` a proxy, linked to the caller, that forwards
  # each message to `pid`: for a test process that holds another name.
  def proxy(core, pid) do
    proxy = spawn_link(fn -> forward(pid) end)
    Process.register(proxy, test_name(core))
  end

  defp forward(pid) do
    receive do
      message -> send(pid, message)
    end

    forward(pid)
  end

  defmacro __using__(opts) do
    limit = Keyword.get(opts, :limit, 2_000)

    points =
      for point <- Keyword.get(opts, :points, [:before_tool, :after_tool]) do
        default = Map.fetch!(@defaults, point)

        quote do
          @impl true
          def unquote(point)(input),
            do: Helyx.Test.Hook.run(__MODULE__, unquote(point), input, unquote(default))
        end
      end

    quote do
      @behaviour Helyx.Hook

      @impl true
      def limit(_point), do: unquote(limit)

      unquote_splicing(points)

      # A handle is `{test_pid, tag}`: the release runs in a Task of its
      # own, with no call context.
      @impl true
      def release(handles, mode, _deadline) do
        for {test, _tag} <- handles, do: send(test, {:released, __MODULE__, handles, mode})
        Enum.filter(handles, &match?({_test, :stuck}, &1))
      end
    end
  end

  def run(module, point, input, default) do
    core = Helyx.Tool.context().core
    send(test_name(core), {:hook, module, point, input})

    case :persistent_term.get({module, core, point}, nil) do
      nil -> default
      fun -> fun.(input)
    end
  end
end

defmodule Helyx.Test.Hook.A do
  @moduledoc false
  use Helyx.Test.Hook
end

defmodule Helyx.Test.Hook.B do
  @moduledoc false
  use Helyx.Test.Hook
end

defmodule Helyx.Test.Hook.Short do
  @moduledoc false
  # A hook with a limit of 100 ms.
  use Helyx.Test.Hook, limit: 100
end

defmodule Helyx.Test.Hook.Before do
  @moduledoc false
  # A hook on `before_tool` only, scripted as the others.
  @behaviour Helyx.Hook
  @impl true
  def limit(_point), do: 2_000
  @impl true
  def before_tool(input), do: Helyx.Test.Hook.run(__MODULE__, :before_tool, input, :allow)
end

defmodule Helyx.Test.Hook.BeforeOnly do
  @moduledoc false
  @behaviour Helyx.Hook
  @impl true
  def limit(:before_tool), do: 1
  @impl true
  def before_tool(_input), do: :allow
end

defmodule Helyx.Test.Hook.NoPoint do
  @moduledoc false
  @behaviour Helyx.Hook
  @impl true
  def limit(_point), do: 1_000
end

defmodule Helyx.Test.Hook.NoLimit do
  @moduledoc false
  @behaviour Helyx.Hook
  @impl true
  def before_tool(_input), do: :allow
  # A limit outside the contract is the point.
  @dialyzer {:nowarn_function, limit: 1}
  @impl true
  def limit(_point), do: nil
end

defmodule Helyx.Test.Hook.Limit do
  @moduledoc false
  # A hook whose limit at each point is the value in the persistent term
  # `{Helyx.Test.Hook.Limit, :ms}`, read at Core start.
  @behaviour Helyx.Hook
  @impl true
  def limit(_point), do: :persistent_term.get({__MODULE__, :ms})
  @impl true
  def after_tool(_input), do: :keep
end

defmodule Helyx.Test.Tool.HookAsk do
  @moduledoc false
  # Calls `Helyx.Hook.ask/1` from its call Task, and gives the error name.
  use Helyx.Test.Tool, name: "hook_ask", description: "Asks as a hook."

  @impl true
  def run(_args, _cwd) do
    {:error, reason} = Helyx.Hook.ask(%{"q" => 1})
    {:ok, Atom.to_string(reason)}
  end
end

defmodule Helyx.Test.Tool.NoPlace do
  @moduledoc false
  # Gives a start answer with no place from `background/0`.
  use Helyx.Test.Tool, name: "no_place", description: "Starts with no place."

  @impl true
  def run(_args, _cwd) do
    Helyx.Tool.started("phantom")
    {:ok, "never"}
  end
end

defmodule Helyx.Test.Tool.SlowRelease do
  @moduledoc false
  # Holds a handle whose release tells the gate `{:releasing, pid}` and
  # waits for `:go`: the hands are busy until then.
  use Helyx.Test.Tool, name: "slow_release", description: "Holds a slow handle."

  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    :ok = Helyx.Tool.hold({:slow, gate})
    {:ok, "held"}
  end

  @impl true
  def release([{:slow, gate}], _mode, _deadline) do
    send(String.to_existing_atom(gate), {:releasing, self()})
    receive do: (:go -> [])
  end
end

defmodule Helyx.Test.Tool.GateAsk do
  @moduledoc false
  # Tells the gate `{:ready, pid}`, waits for `:go`, then asks the
  # clients and gives the answer as JSON.
  use Helyx.Test.Tool, name: "gate_ask", description: "Asks after the gate."

  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    send(String.to_existing_atom(gate), {:ready, self()})
    receive do: (:go -> :ok)
    {:ok, answer} = Helyx.Tool.ask(%{"q" => "now"})
    {:ok, JSON.encode!(answer)}
  end
end

defmodule Helyx.Test.Tool.BgAsk do
  @moduledoc false
  # Goes on in the background, tells the gate `{:bg, pid}`, waits for
  # `:go`, then asks and tells the gate `{:bg_ask, result}`.
  use Helyx.Test.Tool, name: "bg_ask", description: "Asks from the background."

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    gate = String.to_existing_atom(gate)
    {:ok, _place} = Helyx.Tool.background()
    :ok = Helyx.Tool.started("started")
    send(gate, {:bg, self()})
    receive do: (:go -> :ok)
    send(gate, {:bg_ask, Helyx.Tool.ask(%{"q" => "late"})})
    {:ok, "end"}
  end
end

defmodule Helyx.Test.Tool.GateWait do
  @moduledoc false
  # Tells the gate `{:call, pid}` and waits for `:go`.
  use Helyx.Test.Tool, name: "gate_wait", description: "Waits for the gate."

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    send(String.to_existing_atom(gate), {:call, self()})
    receive do: (:go -> {:ok, "waited"})
  end
end

defmodule Helyx.Test.Hook.SettleA do
  @moduledoc false
  # A hook on `before_settle` only (docs/features/before-settle.md).
  use Helyx.Test.Hook, points: [:before_settle]
end

defmodule Helyx.Test.Hook.SettleB do
  @moduledoc false
  use Helyx.Test.Hook, points: [:before_settle]
end

defmodule Helyx.Test.Hook.SettleShort do
  @moduledoc false
  # A `before_settle` hook with a limit of 100 ms.
  use Helyx.Test.Hook, points: [:before_settle], limit: 100
end

defmodule Helyx.Test.Hook.SettleLimit do
  @moduledoc false
  # A `before_settle` hook whose limit is the value in the persistent term
  # `{Helyx.Test.Hook.Limit, :ms}`, read at Core start.
  @behaviour Helyx.Hook
  @impl true
  def limit(_point), do: :persistent_term.get({Helyx.Test.Hook.Limit, :ms})
  @impl true
  def before_settle(_input), do: :settle
end
