defmodule Helyx.Send do
  @moduledoc false
  # The one path of a text to a session that a stop may unload
  # (docs/features/idle-unload.md). The session can stop between the check
  # that it runs and the text: its idle timer message comes first in its
  # mailbox, and the call then gets no reply while its file is complete. A
  # sender loads the session once and sends again, so no sender repeats that
  # retry. It sends again only when the first send proves that the session
  # took nothing; any other end may have taken the text.

  alias Helyx.Session

  @doc """
  Sends `send`, a function of a session, and sends again with the session of
  `load` only when the first send proves that it took nothing: no process
  held its id (`{:error, {:stopped, :noproc}}`), or it stopped for idleness
  (`{:error, {:stopped, {:shutdown, :idle}}}`). Any other end gives
  `{:error, :session_not_found}` and no second send. `load` gives
  `{:ok, session}` or the error of the caller.
  """
  @spec text(Session.t(), (Session.t() -> result), (-> {:ok, Session.t()} | error)) ::
          result | error
        when result: term(), error: term()
  def text(%Session{} = session, send, load) do
    case send.(session) do
      {:error, {:stopped, reason}} when reason == :noproc or reason == {:shutdown, :idle} ->
        loaded(load, send)

      {:error, {:stopped, _reason}} ->
        {:error, :session_not_found}

      result ->
        result
    end
  end

  defp loaded(load, send) do
    with {:ok, session} <- load.(), do: send.(session)
  end
end
