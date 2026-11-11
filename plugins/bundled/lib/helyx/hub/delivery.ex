defmodule Helyx.Hub.Delivery do
  @moduledoc false
  # The delivery Task of one wake-up (`docs/features/hub.md`, decision 12):
  # at most once. It runs under the task supervisor of its Hub, linked to
  # the Hub process, and every write goes through a Hub call to
  # `Helyx.Hub.Wake`, which applies it only while the row holds what the
  # start of this Task wrote.
  #
  # The Task holds the prompt of its row, at most 16,384 bytes, and no
  # subscription; the Hub kills it 120,000 ms after its start.

  alias Helyx.Hub
  alias Helyx.Hub.Params

  def run(hub, core, row) do
    session = %Helyx.Session{id: row.session_id, core: core}

    with :ok <- running(hub, core, session, row),
         :ok <- Hub.call(hub, {:wake_decide, row}) do
      send_prompt(hub, session, row)
    end

    :ok
  end

  # Step 1: a session that does not run is resumed, after a place of the
  # live set of the owner (decision 14).
  defp running(hub, core, session, row) do
    if Helyx.Session.pid(session), do: :ok, else: resume(hub, core, session, row)
  end

  defp resume(hub, core, session, row) do
    with :ok <- Hub.call(hub, {:wake_place, row}) do
      case Helyx.Sessions.resume(core, id: session.id) do
        # A session that the live set did not take gets no send: the row
        # stays due at its next try.
        {:ok, resumed} ->
          Hub.call(hub, {:wake_resumed, row, Helyx.Session.pid(resumed)})

        {:error, reason} ->
          _ = Hub.call(hub, {failed(reason), row})
          :stop
      end
    end
  end

  # The resume errors that a later try can pass; a missing file also
  # deletes the record of the session (decision 8); any other refuses.
  defp failed(:too_many_sessions), do: :wake_retry
  defp failed(:editing), do: :wake_retry
  defp failed(:open_timeout), do: :wake_retry
  defp failed(:not_found), do: :wake_gone
  defp failed(_reason), do: :wake_refused

  # Step 3. Only `:turn_running` and `:queue_full` prove that the session
  # took nothing. `:session_not_found` and an exit of the call leave
  # `unconfirmed`: the session may have taken the prompt before it went
  # down. `:text_too_large`, `:invalid_utf8` and `:invalid_origin` cannot come (a checked
  # prompt, an origin id of 12 bytes); they crash the Task, which leaves
  # `unconfirmed` too.
  defp send_prompt(hub, session, row) do
    case prompt(session, row) do
      :ok -> Hub.call(hub, {:wake_outcome, row, {:delivered, Params.cut(row.prompt)}})
      {:error, busy} when busy in [:turn_running, :queue_full] -> back(hub, row)
      {:error, :session_not_found} -> unconfirmed(hub, row)
      :exit -> unconfirmed(hub, row)
    end
  end

  defp back(hub, row), do: Hub.call(hub, {:wake_outcome, row, :back})
  defp unconfirmed(hub, row), do: Hub.call(hub, {:wake_outcome, row, :unconfirmed})

  # The origin id is the delivery id of the pending wake-up, which names no
  # schedule and no run.
  defp prompt(session, row) do
    Helyx.Session.prompt(session, row.prompt, origin: %{kind: :product, id: row.delivery_id})
  catch
    :exit, _reason -> :exit
  end
end
