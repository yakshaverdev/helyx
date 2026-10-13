defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session. `id/0` is the prefix in a
  model ref such as `fake/echo`.

  Every provider runs in one provider process per session, a Task of the
  hands. `init/3` starts it. `request/3` gets a `t:request/0` from Core and
  replies now or later with the action `{:reply, from, value}`. `info/2`
  gets every other message of the process. A provider that holds a handle
  (`Helyx.Tool.hold/1`) implements `release/3`. A model provider implements
  `stream/3` and adds `use Helyx.Provider.Loop`, which defines the three
  callbacks.

  The `Helyx.Context` of a `{:turn, ...}` or a `{:context, ...}` request is
  for one call: its `system` and `tools` are what a model provider sends on
  that call. A harness provider may use only its `messages`.

  The options of `init/3` include `:resume_id`, the id of a `:resume_id`
  event of an earlier provider process to resume, or nil, and
  `:resume_usage`, the sum of the usages of the messages since that event,
  or nil when none has one.

  Rules that every provider follows:

    * A steer is taken at most once. The session takes a steer at the
      first `{:user_message, steer_id}` event for it, and drops an id that
      is not a sent steer of the turn, or is taken already.
    * A tool call or a tool request with an empty id fails the turn: a
      result names its call by the id.
    * When its wire protocol reports it, a provider gives the stop reason
      `:max_tokens` for an answer that stopped at the token limit, and
      `:refused` for an answer that the provider filtered or the model
      refused. `Helyx.Provider.Codex` reports neither. In two cases a
      stop reason that arrives while a steer waits is lost
      (`docs/features/session-lifecycle.md`, "Current limits").
    * A Helyx tool request whose arguments are not a JSON object never
      runs. A provider can send such arguments as their raw text. In a turn
      that continues, the request gets an error result, so the model can
      correct it (`docs/features/rejected-tool-call.md`).
    * A provider that keeps its own history answers `{:compact, ...}`
      with `:ok` and runs the compaction as that turn; a compaction
      gives `{:compaction, tokens_before, tokens_after}`, in that turn or
      in any other, with nil for a count that it does not know. A
      provider that keeps no history answers `:unsupported`
      (`docs/features/harness-compaction.md`).

  The types below give the requests, the actions, and the events. The
  rules of the protocol (replies, events, deadlines) and their reasons are
  in `docs/features/one-provider-path.md`, "The provider protocol", and its
  bounds in the "Bounds" sections of `docs/features/session-lifecycle.md`
  and `docs/features/coding-agent.md`. ADR 0002 and ADR 0007 decide the
  provider process.
  """

  use Helyx.Interface, mode: :multi

  @type stop_reason :: Helyx.Message.stop_reason()

  @type stream_event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_call, Helyx.Message.ToolCall.t()}
          | {:done, %{stop_reason: stop_reason(), usage: Helyx.Usage.t() | nil}}
          | {:error, term()}
          | {:message_end, stop_reason(), Helyx.Usage.t() | nil}
          | {:tool_result, String.t(), {:ok | :error, String.t()}}
          | {:resume_id, String.t(), non_neg_integer()}
          | {:user_message, String.t()}
          | {:compaction, tokens_before :: non_neg_integer() | nil,
             tokens_after :: non_neg_integer() | nil}
          | {:tool_request, call_id :: String.t(), name :: String.t(),
             arguments :: map() | String.t()}
          | :turn_start

  @typedoc "The ref of a request from Core, for its reply."
  @type from :: reference()

  @type request ::
          {:turn, turn_id :: String.t(), Helyx.Context.t()}
          | {:compact, turn_id :: String.t(), instructions :: String.t()}
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
              {:ok, [action()], term()}
              | {:stop, reason :: term(), term()}
              | {:stop, reason :: term(), [action()], term()}

  @optional_callbacks release: 3
end
