defmodule Helyx.Session.Ask do
  @moduledoc false
  # The ask of `Helyx.Tool.ask/1` (`kind` `:tool`) and of
  # `Helyx.Hook.ask/1` (`:hook`). It goes to the session, which checks the
  # caller against the record of the Tasks that the hands started
  # (docs/features/hooks.md, "The caller check of an ask"). A process with
  # the call context that the hands did not start, such as one that a tool
  # or a hook started, gets `:not_running`.

  # The most bytes of the JSON of a request.
  @max_request_bytes 65_536

  def max_request_bytes, do: @max_request_bytes

  # The wait of a call or hook Task, before any plugin code runs (a hook
  # Task arms the kill of its limit first), for the session's go: the
  # session sends it after it handled the record of the Task that the
  # hands sent. So the session handled the record before the Task can
  # ask, by the order of what the session itself received and sent. A
  # background run waits for it after its start answer too
  # (docs/features/hooks.md).
  def await_go do
    receive do
      :helyx_go -> :ok
    end
  end

  # The kind of the record of a Task of the hands with the turn and the id
  # of `Helyx.Session.Hands.spawn_task/5`, or nil: a call Task asks with
  # `Helyx.Tool.ask/1`, a hook Task with `Helyx.Hook.ask/1`. A Task with no
  # turn (the provider process) and a `before_settle` chain Task, which
  # runs no plugin code, have none, and wait for no go.
  def asker(nil, _id), do: nil
  def asker(_turn_id, {:settle, _ref}), do: nil
  def asker(_turn_id, {:hook, call_id}), do: {:hook, call_id}
  def asker(_turn_id, call_id), do: {:tool, call_id}

  def ask(kind, request) do
    %{core: core, session_id: id, call_id: call_id, tool: tool} = Helyx.Tool.context()

    if Helyx.Session.Input.json_object(request, @max_request_bytes) != :ok,
      do: raise(ArgumentError, "an ask request is a JSON object of at most 64 KiB")

    GenServer.call(
      Helyx.Session.Server.via(core, id),
      {:ask, kind, call_id, tool, request},
      :infinity
    )
  end
end
