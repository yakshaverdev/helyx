defmodule Helyx.Test.Hook do
  @moduledoc false
  # Test hook plugins (docs/features/hooks.md). Each one runs the function
  # that a test set for its point and its Core (`script/3`), with the call
  # input, and sends `{:hook, module, point, input}` to the process
  # registered as `<core>.Test` first. A point with no function allows or
  # keeps. `release/3` sends `{:released, module, handles, mode}` to the
  # pid of each handle `{pid, tag}`, and confirms every handle whose tag
  # is not `:stuck`.

  # Sets `fun` for `module` at `point` in the Core `core`.
  def script(core, module, point, fun), do: :persistent_term.put({module, core, point}, fun)

  def test_name(core), do: Module.concat(core, Test)

  defmacro __using__(opts) do
    limit = Keyword.get(opts, :limit, 2_000)

    quote do
      @behaviour Helyx.Hook

      @impl true
      def limit(_point), do: unquote(limit)

      @impl true
      def before_tool(input), do: Helyx.Test.Hook.run(__MODULE__, :before_tool, input, :allow)

      @impl true
      def after_tool(input), do: Helyx.Test.Hook.run(__MODULE__, :after_tool, input, :keep)

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
