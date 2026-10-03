defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session. `id/0` is the prefix in a
  model ref such as `fake/echo`.

  Every provider runs in one provider process per session, a Task of the
  hands. `init/3` starts it. `request/3` gets a `t:request/0` from Core and
  replies now or later with the action `{:reply, from, value}`. `info/2`
  gets every other message of the process. A provider that holds a handle
  (`Helyx.Tool.hold/1`) implements `release/3`. An API provider implements
  `stream/3` and adds `use Helyx.Provider.Loop`, which defines the three
  callbacks.

  The types below give the requests, the actions, and the events. The
  rules of the protocol (replies, events, deadlines) are in
  `docs/features/one-provider-path.md`, "The provider protocol", and its
  bounds in the "Bounds" sections of `docs/features/session-lifecycle.md`
  and `docs/features/coding-agent.md`. The reasons
  are in ADR 0002 and ADR 0007.
  """

  use Helyx.Interface, mode: :multi, required: true

  @type stop_reason :: Helyx.Message.stop_reason()

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:done, %{stop_reason: stop_reason(), usage: map()}}
          | {:error, term()}
          | {:message_end, stop_reason(), map()}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:resume, String.t(), non_neg_integer()}
          | {:user_message, String.t()}
          | {:tool_request, call_id :: String.t(), name :: String.t(),
             arguments :: map() | String.t()}
          | :turn_start

  @typedoc "The ref of a request from Core, for its reply."
  @type from :: reference()

  @type request ::
          {:turn, turn_id :: String.t(), Helyx.Context.t()}
          | {:steer, turn_id :: String.t(), steer_id :: String.t(), text :: String.t()}
          | {:interrupt, turn_id :: String.t()}
          | {:tool_result, turn_id :: String.t(), call_id :: String.t(),
             {:ok | :error, String.t()}}
          | {:context, turn_id :: String.t(), {:ok, Helyx.Context.t()} | {:error, term()}}
          | :close
          | :idle_close

  @type action ::
          {:event, turn_id :: String.t(), stream_event()}
          | {:reply, from(), term()}
          | {:cancel_tool, call_id :: String.t()}
          | {:need_context, turn_id :: String.t()}

  @doc """
  Finds the provider plugin whose id matches a model ref prefix. It reads the
  ids that Core checked at start and calls no plugin code.
  """
  @spec find(Helyx.Core.name(), String.t()) ::
          {:ok, module()} | {:error, {:unknown_provider, String.t()}}
  def find(core, id) do
    with :error <- Map.fetch(Helyx.Core.provider_ids(core), id),
         do: {:error, {:unknown_provider, id}}
  end

  @callback id() :: String.t()
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel | :retry,
              deadline :: integer()
            ) ::
              [term()]

  @callback init(model :: String.t(), tools :: [Helyx.Tool.spec()], opts :: keyword()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback request(request(), from(), state :: term()) :: {:ok, [action()], term()}
  @callback info(msg :: term(), state :: term()) ::
              {:ok, [action()], term()} | {:stop, reason :: term(), term()}

  @optional_callbacks release: 3
end
