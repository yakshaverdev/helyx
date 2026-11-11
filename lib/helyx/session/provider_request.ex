defmodule Helyx.Session.ProviderRequest do
  @moduledoc false
  # A request of Core to the provider process, with its armed kill (ADR 0007,
  # docs/features/session-lifecycle.md, "Deadlines").

  @type t :: Helyx.Provider.request()

  @doc """
  Sends `request` to the provider process `pid` with a kill armed at `ms`, and
  returns the `from` ref of its reply, `{:provider_reply, from, kind, value}` to
  the caller (see `kind/1`).
  """
  @spec ask(pid(), t(), pos_integer()) :: reference()
  def ask(pid, request, ms) do
    {:ok, tref} = :timer.kill_after(ms, pid)
    from = make_ref()
    send(pid, {:provider_request, from, tref, request})
    from
  end

  @doc """
  Answers the request `from` of `kind` to `session` with `value`: the armed kill
  `tref` is cancelled first.
  """
  @spec answer(pid(), reference(), :timer.tref(), atom(), term()) :: term()
  def answer(session, from, tref, kind, value) do
    :timer.cancel(tref)
    send(session, {:provider_reply, from, kind, value})
  end

  @doc """
  The first element of the request (`:turn`, `:steer`, `:tool_result`, ...), or
  the request itself for `:close` and `:idle_close`.
  """
  @spec kind(t()) :: atom()
  def kind({kind, _turn_id, _id, _value}) when kind in [:steer, :tool_result, :approval],
    do: kind

  def kind({kind, _turn_id, _value}), do: kind
  def kind({kind, _turn_id}), do: kind
  def kind(close) when close in [:close, :idle_close], do: close

  @doc "Whether a request of `kind` takes the reply `value`."
  @spec reply?(atom(), term()) :: boolean()
  def reply?(_kind, :ok), do: true
  def reply?(:idle_close, :busy), do: true
  def reply?(:steer, :rejected), do: true
  def reply?(:compact, :unsupported), do: true
  def reply?(kind, {:error, _reason}) when kind in [:turn, :compact, :interrupt, :steer], do: true
  def reply?(_kind, _value), do: false

  @doc """
  The stop of the provider process that a reply gives, or nil when the process
  goes on.
  """
  # After an error answer to a turn, a compaction, or an interrupt Helyx does
  # not know the state of the provider, so the loop ends. An error answer to a
  # steer leaves only that steer unknown, so the loop goes on.
  @spec stop_after(atom(), term()) :: {:stop, term()} | nil
  def stop_after(kind, :ok) when kind in [:close, :idle_close], do: {:stop, :closed}

  def stop_after(kind, {:error, reason}) when kind != :steer,
    do: {:stop, {:provider_error, kind, reason}}

  def stop_after(_kind, _value), do: nil
end
