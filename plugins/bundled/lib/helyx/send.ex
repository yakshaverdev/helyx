defmodule Helyx.Send do
  @moduledoc false
  # The one path of a text to a session that a stop may unload
  # (docs/features/idle-unload.md). The session can stop between the check
  # that it runs and the text: its idle timer message comes first in its
  # mailbox, and the call then gets `{:error, :session_not_found}` while its
  # file is complete. A sender loads the session once and sends again, so no
  # sender repeats that retry. A second failure, or a failed load, is the
  # result of the caller.

  alias Helyx.Session

  @doc """
  Sends `send`, a function of a session, or loads the session with `load` and
  sends again when the send answers `{:error, :session_not_found}`. `load`
  gives `{:ok, session}` or the error of the caller.
  """
  @spec text(Session.t(), (Session.t() -> result), (-> {:ok, Session.t()} | error)) ::
          result | error
        when result: term(), error: term()
  def text(%Session{} = session, send, load) do
    case send.(session) do
      {:error, :session_not_found} -> loaded(load, send)
      result -> result
    end
  end

  defp loaded(load, send) do
    with {:ok, session} <- load.(), do: send.(session)
  end
end
