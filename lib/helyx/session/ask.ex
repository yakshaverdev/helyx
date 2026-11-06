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
