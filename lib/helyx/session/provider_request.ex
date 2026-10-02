defmodule Helyx.Session.ProviderRequest do
  @moduledoc false
  # A request of Core to the provider process (ADR 0007,
  # `docs/features/long-lived-harness.md`): its send with an armed kill, the
  # cancel of the kill at the answer, its kind, the replies that its kind
  # takes, and the replies that end the provider process.
  #
  # Every session request but `{:turn_dropped, ...}` (`tell/2`) has a kill of
  # the provider process armed at the OTP timer server (`ask/3`). The loop of
  # `Helyx.Session.ProviderProcess` cancels the kill when the provider
  # replies, and sends the reply after the cancel (`answer/5`). A callback that blocks
  # also blocks the cancel, so a blocked loop is always killed at the bound,
  # whatever the session and the hands do. The timer can fire during the
  # cancel, so a reply can still be followed by the kill; the session takes
  # the `:provider_down` as the last word.

  @type t :: Helyx.Provider.request() | {:tool_start, String.t(), String.t()}

  @doc """
  Sends `request` to the provider process `pid` with a kill armed at `ms`,
  and returns the `from` ref of its reply, `{:provider_reply, from, kind,
  value}` to the caller (see `kind/1`).
  """
  @spec ask(pid(), t(), pos_integer()) :: reference()
  def ask(pid, request, ms) do
    {:ok, tref} = :timer.kill_after(ms, pid)
    from = make_ref()
    send(pid, {:provider_request, from, tref, request})
    from
  end

  @doc "Sends `request` to the provider process `pid` with no kill and no reply."
  @spec tell(pid(), {:turn_dropped, String.t()}) :: term()
  def tell(pid, request), do: send(pid, {:provider_request, make_ref(), nil, request})

  @doc """
  Answers the request `from` of `kind` to `session` with `value`: the
  armed kill `tref` is cancelled first.
  """
  @spec answer(pid(), reference(), :timer.tref(), atom(), term()) :: term()
  def answer(session, from, tref, kind, value) do
    :timer.cancel(tref)
    send(session, {:provider_reply, from, kind, value})
  end

  @doc """
  The first element of the request (`:turn`, `:steer`, `:tool_start`, ...),
  or the request itself for `:close` and `:idle_close`.
  """
  @spec kind(t()) :: atom()
  def kind({kind, _turn_id, _id, _value}) when kind in [:steer, :tool_result], do: kind
  def kind({kind, _turn_id, _value}), do: kind
  def kind({kind, _turn_id}), do: kind
  def kind(close) when close in [:close, :idle_close], do: close

  @doc "Whether a request of `kind` takes the reply `value`."
  @spec reply?(atom(), term()) :: boolean()
  def reply?(_kind, :ok), do: true
  def reply?(:idle_close, :busy), do: true
  def reply?(:steer, :rejected), do: true
  def reply?(kind, {:error, _reason}) when kind in [:turn, :interrupt, :steer], do: true
  def reply?(_kind, _value), do: false

  @doc """
  The stop of the provider process that a reply gives, or nil when the
  process goes on.
  """
  # After an error answer to a turn or an interrupt Helyx does not know the
  # state of the program, so the loop ends: the port closes, and the
  # watchdog stops the program with no end of input. An error answer to a
  # steer leaves only that steer unknown, so the loop goes on. An idle
  # close with `:ok` exited as a close; with `:busy` the program stays.
  @spec stop_after(atom(), term()) :: {:stop, term()} | nil
  def stop_after(kind, :ok) when kind in [:close, :idle_close], do: {:stop, :closed}

  def stop_after(kind, {:error, reason}) when kind != :steer,
    do: {:stop, {:provider_error, kind, reason}}

  def stop_after(_kind, _value), do: nil
end
