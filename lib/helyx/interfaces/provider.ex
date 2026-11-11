defmodule Helyx.Provider do
  @moduledoc """
  Produces assistant messages for a session. `id/0` is the prefix in a model
  ref such as `fake/echo`.

  The protocol is in `docs/features/one-provider-path.md`, "The provider
  protocol"; ADR 0002 and ADR 0007 decide the provider process.

  Rules that every provider follows:

    * A steer is taken at most once. The session takes a steer at the first
      `{:user_message, steer_id}` event for it, and drops an id that is
      not a sent steer of the turn, or is taken already.
    * A tool call or a tool request with an empty id fails the turn: a
      result names its call by the id.
    * When its wire protocol reports it, a provider gives the stop reason
      `:max_tokens` or `:refused`; `Helyx.Provider.Codex` reports neither.
    * The arguments of a tool call or a Helyx tool request are a map; other
      arguments fail the turn, and the error holds `%{}` in place of raw
      text (`docs/features/rejected-tool-call.md`).
    * A provider that keeps its own history answers `{:compact, ...}` with
      `:ok` and gives `{:compaction, tokens_before, tokens_after}`; one that
      keeps no history answers `:unsupported`
      (`docs/features/harness-compaction.md`).
    * A provider that asks for a decision on a call of its own tools gives
      `{:approval, approval_id, call_id}`: `approval_id` is its own id of
      the request, 1 to 256 bytes of valid UTF-8, unique among its pending
      requests of the turn; `call_id` names an open call of the turn that
      it runs itself. The session answers each request at most once, with
      `{:approval, turn_id, approval_id, :allow | {:deny, reason}}`, and
      answers every request of a provider process that it did not stop
      (ADR 0013 §4, `docs/features/hooks.md`, "Harness approvals").
  """

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
          | {:approval, approval_id :: String.t(), call_id :: String.t()}
          | {:ui_block, call_id :: String.t() | nil, key :: String.t(), Helyx.UIBlock.t()}
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
          | {:approval, turn_id :: String.t(), approval_id :: String.t(),
             :allow | {:deny, reason :: String.t()}}
          | :close
          | :idle_close

  @type action ::
          {:event, turn_id :: String.t(), stream_event()}
          | {:reply, from(), term()}
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
  @callback max_output_tokens?() :: boolean()
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel,
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

  @optional_callbacks release: 3, max_output_tokens?: 0
end
