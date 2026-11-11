defmodule Helyx.Session.Ask do
  @moduledoc false
  # The ask of `Helyx.Tool.ask/1` (`kind` `:tool`) and of `Helyx.Hook.ask/1`
  # (`:hook`). It goes to the session, which checks the caller against the
  # record of the Tasks that the hands started (docs/features/hooks.md). A
  # process with the call context that the hands did not start gets
  # `:not_running`.

  # The most bytes of the JSON of a request.
  @max_request_bytes 65_536

  def max_request_bytes, do: @max_request_bytes

  # The wait of a call or hook Task, before any plugin code runs, for the
  # session's go: the session sends it after it handled the record of the Task,
  # so the session handled the record before the Task can ask. A background run
  # waits for it after its start answer too (docs/features/hooks.md).
  def await_go do
    receive do
      :helyx_go -> :ok
    end
  end

  # The record of an ask of a Task of `kind`
  # (`Helyx.Session.Hands.Entry`): `{:tool, call_id}` for a call Task,
  # `{:hook, chain_id}` for a hook Task, and nil for every other kind, which
  # runs no plugin code and waits for no go.
  def asker({:call, call_id}), do: {:tool, call_id}
  def asker({:hook, chain_id, _run}), do: {:hook, chain_id}
  def asker(_kind), do: nil

  def ask(kind, request) do
    %{core: core, session_id: id, call_id: call_id, tool: tool} = Helyx.Tool.context()

    if Helyx.Session.Input.json_object(request, @max_request_bytes) != :ok,
      do: raise(ArgumentError, "an ask request is a JSON object of at most 64 KiB")

    # A request with a kind is an input UI block (docs/features/ui-blocks.md);
    # the walk above checked UTF-8, the digits, and the size.
    if is_map_key(request, "kind") and not Helyx.UIBlock.envelope?(request),
      do: raise(ArgumentError, "an ask request with a kind is a UI block")

    GenServer.call(
      Helyx.Session.Server.via(core, id),
      {:ask, kind, call_id, tool, request},
      :infinity
    )
  end
end
