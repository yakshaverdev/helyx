defmodule Helyx.Session do
  @moduledoc """
  One conversation with one agent.

  A session is a supervised process under Core. It owns the transcript and
  the current turn. Clients subscribe to its events and send prompts.

      {:ok, session} = Helyx.Session.start(core, model: "fake/echo")
      {:ok, snapshot, ref} = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "hello")
      # receive {:helyx_event, %Helyx.Event{}} ...
      # then {:DOWN, ^ref, :process, _pid, reason} when the session
      # ends; Helyx.Session.end_reason(reason) is :stopped or :crashed

  The turn, the queues, the abort, the provider process, and the late calls
  are in `docs/features/session-lifecycle.md`; the subscription is in
  `docs/features/session-subscribers.md`. Every message has an id, and every
  user message an origin (`docs/features/message-identity.md`).
  """

  alias Helyx.ModelRef
  alias Helyx.Session.{Call, History, Id, Input, Server, Snapshot}
  alias Helyx.Session.Server.State

  @enforce_keys [:id, :core]
  defstruct [:id, :core]

  # The timeout of each call of the contract but `abort/1`.
  @call_timeout_ms 5_000

  @type t :: %__MODULE__{id: String.t(), core: Helyx.Core.name()}

  @typedoc "An error of `prompt/3`, `steer/3`, and `follow_up/3`."
  @type send_error ::
          :text_too_large | :invalid_utf8 | :invalid_origin | :queue_full | :session_not_found

  @doc "The most bytes of a text to `prompt/3`, `steer/3`, `follow_up/3`, and `compact/2`: 4 MiB."
  @spec max_text_bytes() :: pos_integer()
  defdelegate max_text_bytes, to: Input

  @typedoc "An error that stops a model ref from resolving to a provider plugin."
  @type model_error ::
          {:invalid_model_ref, String.t()}
          | {:unknown_provider, String.t()}
          | {:max_output_tokens_unsupported, String.t()}

  @doc """
  Starts a session under Core. `:model` is required, and the ref resolves as
  in `set_model/2`. `:cwd` defaults to the current directory, valid UTF-8
  with no NUL byte, else `{:error, :invalid_cwd}`. `:tools` names the tools,
  all if nil, and with it the session opens no tool source (`mcp-client.md`);
  `:parent` links a child to a tool call (`docs/features/agent-tool.md`);
  `:model_context` names a ModelContext plugin, the first if nil
  (`{:error, :invalid_model_context}`); `:provider_opts` is a keyword list
  for each `init/3` (`{:error, :invalid_provider_opts}`); `:max_output_tokens`
  limits each assistant message (`docs/features/output-limit.md`). With
  `:sessions_dir` the session is written to disk: `{:error, {:session_locked,
  id}}`, `{:error, {:lock_failed, text}}`, `{:error, :open_timeout}`,
  `{:error, {:create_failed, reason}}`, or `{:error, :too_many_sessions}`
  (`docs/features/session-lock.md`, `docs/features/server-management.md`).
  """
  @spec start(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def start(core \\ Helyx.Core, opts) do
    # The file is created only after the plugins resolve, which narrows the
    # window for an orphan file from a failed start. A crash of the
    # session's open after the create still leaves one.
    with {:ok, cwd} <- Input.cwd_option(opts),
         {:ok, provider_opts} <- Input.provider_opts(opts),
         {:ok, parent, only, model_context, limit} <- Input.start_options(core, opts),
         id = if(parent, do: Id.child(parent.session_id, parent.call_id), else: Id.new()),
         {:ok, tools, sources} <- Input.tools(core, only),
         concurrent = Helyx.Tool.concurrent(tools),
         {:ok, {ref, provider}} <- Input.model(core, Keyword.fetch!(opts, :model), limit),
         # The folders come before the lock, whose file is in them.
         :ok <- mkdir(opts[:sessions_dir], cwd, parent) do
      state = %State{id: id, core: core, model: ref, provider: provider, cwd: cwd}
      init = %{provider_opts: provider_opts, max_output_tokens: limit}

      Server.create(
        %{state | init: init, plugins: %{state.plugins | model_context: model_context}},
        {tools, concurrent, sources},
        Server.Open.create_spec(opts[:sessions_dir], id, cwd, ModelRef.to_string(ref), parent)
      )
    end
  end

  defp mkdir(nil, _cwd, _parent), do: :ok
  defp mkdir(dir, cwd, parent), do: Helyx.Session.File.mkdir(dir, cwd, parent)

  @doc """
  Resumes from `:sessions_dir` the session `Helyx.Session.File.pick/3` picks:
  the newest of the working directory, or with `:id` that session, in the
  folder of its header when no `:cwd` is given. `:cwd`, the tool checks, the
  model ref, `:provider_opts`, the lock, the cap, and the read bounds are as
  in `start/2`; a file over its bounds gives `{:error, {:too_large, text}}`
  or `{:error, :open_timeout}`. A session that runs in this Core is attached,
  and other `:provider_opts` give `{:error, :provider_opts_differ}`
  (`docs/features/interrupted-calls.md`, `docs/features/server-management.md`).
  """
  @spec resume(Helyx.Core.name(), keyword()) :: {:ok, t()} | {:error, model_error() | term()}
  def resume(core \\ Helyx.Core, opts) do
    dir = Keyword.fetch!(opts, :sessions_dir)
    header? = Keyword.has_key?(opts, :id) and not Keyword.has_key?(opts, :cwd)

    with {:ok, cwd} <- if(header?, do: {:ok, nil}, else: Input.cwd_option(opts)),
         {:ok, provider_opts} <- Input.provider_opts(opts),
         {:ok, tools, sources} <- Input.tools(core, nil),
         concurrent = Helyx.Tool.concurrent(tools),
         {:ok, path, cwd} <- Helyx.Session.File.pick(dir, cwd, Keyword.take(opts, [:id])) do
      id = Path.basename(path, ".jsonl")
      state = %State{id: id, core: core, model: nil, provider: nil, cwd: cwd}
      state = %{state | init: %{state.init | provider_opts: provider_opts}}
      Server.start(state, {tools, concurrent, sources}, {path, &Server.Open.load(&1, path)})
    end
  end

  @doc """
  Subscribes the caller to the session's events, delivered as
  `{:helyx_event, event}`, and returns `{:ok, snapshot, ref}`, where `ref` is
  the caller's monitor of the session process. With `answers: true` the
  caller can answer asks (`answer/3`). One end signal, `{:DOWN, ref, :process,
  pid, reason}`, follows the last event; `end_reason/1` maps it to `:stopped`
  or `:crashed`. With `tail: n` (1 to 1,000) the snapshot holds the newest
  messages only, and `history/4` gives the older ones. With
  `after: {instance_id, seq}` the result is `{:ok, {:replay, events}, ref}`
  when the replay ring serves the interval, else the snapshot. Errors:
  `{:error, :session_not_found}`, `{:error, :invalid_after}`, and
  `{:error, :invalid_limit}` (`docs/features/session-subscribers.md`,
  `docs/features/replay-ring.md`, `docs/features/end-signal.md`).
  """
  @spec subscribe(t(), keyword()) ::
          {:ok, Snapshot.t() | {:replay, [Helyx.Event.t()]}, reference()}
          | {:error, :session_not_found | :invalid_limit | :invalid_after}
  def subscribe(%__MODULE__{} = session, opts \\ []) do
    case {History.subscribe(opts), pid(session)} do
      {{:error, _} = error, _pid} -> error
      {_opts, nil} -> {:error, :session_not_found}
      {{:ok, opts}, pid} -> Call.subscribe(pid, opts, @call_timeout_ms)
    end
  end

  @doc """
  Acks every event of the caller's subscription up to `seq`; with an event in
  place of `seq` it acks only each 1,024th `seq`. Past 16,384 unacked events
  the session ends the subscription with `{:helyx_end, ref, :slow}`
  (`docs/features/replay-ring.md`).
  """
  @spec ack(t(), non_neg_integer() | Helyx.Event.t()) :: :ok
  def ack(session, %Helyx.Event{seq: seq}),
    do: if(rem(seq, 1_024) == 0, do: ack(session, seq), else: :ok)

  def ack(%__MODULE__{} = session, seq) when is_integer(seq) and seq >= 0 do
    with pid when is_pid(pid) <- pid(session), do: send(pid, {:ack, self(), seq})
    :ok
  end

  @doc """
  A page of the live transcript before the message with id `before`, oldest
  first, `limit: n` (1 to 1,000, default 200) in place of `tail`. `next` is
  the id to pass for the page before it, nil when `older` is 0
  (`docs/features/session-snapshot.md`, "Tail").
  """
  @spec history(t(), String.t(), String.t(), keyword()) ::
          {:ok, History.history_page()}
          | {:error, :session_not_found | :instance_changed | :unknown_message | :invalid_limit}
  def history(%__MODULE__{} = session, instance_id, before, opts \\ [])
      when is_binary(instance_id) and is_binary(before) do
    with {:ok, limit} <- History.limit(opts),
         do: call(session, {:history, instance_id, before, limit})
  end

  @max_answer_bytes 16_384

  @doc "The most bytes of the JSON of an answer (`answer/3`)."
  @spec max_answer_bytes() :: pos_integer()
  def max_answer_bytes, do: @max_answer_bytes

  @doc """
  Gives an answer that passes `check_answer/1` to the open ask `ask_id`; the
  session emits `:ask_end`. Any other id, as of an answered ask or one whose
  call or turn ended, gets `{:error, :not_waiting}` (`docs/features/question-tool.md`).
  """
  @spec answer(t(), String.t(), map()) ::
          :ok | {:error, :invalid_answer | :not_waiting | :session_not_found}
  def answer(%__MODULE__{} = session, ask_id, answer) when is_binary(ask_id) do
    with :ok <- check_answer(answer), do: call(session, {:answer, ask_id, answer})
  end

  @doc """
  Checks an answer with no session: a JSON object of valid UTF-8 whose JSON
  is at most #{@max_answer_bytes} bytes. The check stops past the bound, so
  a transport runs it before a worker holds the answer.
  """
  @spec check_answer(term()) :: :ok | {:error, :invalid_answer}
  def check_answer(answer) do
    case Input.json_object(answer, @max_answer_bytes) do
      :ok -> :ok
      :error -> {:error, :invalid_answer}
    end
  end

  @doc """
  The reason of an end signal as a client gets it: `:stopped` for an exit
  with `:normal`, `:shutdown`, or `{:shutdown, term}`, and `:crashed` for
  any other. The supervisor logs the full reason.
  """
  @spec end_reason(term()) :: :stopped | :crashed
  def end_reason(reason) when reason in [:normal, :shutdown], do: :stopped
  def end_reason({:shutdown, _}), do: :stopped
  def end_reason(_reason), do: :crashed

  @doc """
  The result of a tool call that the session ended without a result, such
  as at an abort. Clients match this value.
  """
  @spec aborted_result() :: {:error, String.t()}
  def aborted_result, do: {:error, "aborted"}

  @doc "The pid behind a session handle, or nil when the session is not running."
  @spec pid(t()) :: pid() | nil
  def pid(%__MODULE__{id: id, core: core}) do
    GenServer.whereis(Server.via(core, id))
  rescue
    # The Registry is gone with its Core, and so is the session.
    ArgumentError -> nil
  end

  @doc """
  Sends a prompt. Starts a turn if none is running. Errors:
  `{:error, :text_too_large}`, `{:error, :invalid_utf8}`, and
  `{:error, :queue_full}`. Its message has the origin `:user`; product code
  passes `origin: %{kind: :product, id: id}`, an id of 1 to 256 bytes of
  UTF-8, unique per call, else `{:error, :invalid_origin}`. `steer/3` and
  `follow_up/3` take it too (`docs/features/message-identity.md`).
  """
  @spec prompt(t(), String.t(), keyword()) :: :ok | {:error, :turn_running | send_error()}
  def prompt(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :prompt, text, opts)

  @doc """
  Steers the running turn; with no turn running it starts a turn, like a
  prompt. `:ok` means that the session accepted the steer, which counts with
  the open sent steers to 32 (`{:error, :queue_full}`). The text takes the
  checks of `prompt/3`. An abort or a failure gives a queued steer back in a
  `:queue_dropped` event, and an unconfirmed one gets a `:steer_unconfirmed`
  event (`docs/features/session-lifecycle.md`, "Turn states", "Steer").
  """
  @spec steer(t(), String.t(), keyword()) :: :ok | {:error, send_error()}
  def steer(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :steer, text, opts)

  @doc """
  Queues a follow-up prompt, which opens its own turn after the current one
  ends normally. With no turn running it starts a turn at once. The text
  takes the checks of `prompt/3`, and a full queue gives
  `{:error, :queue_full}` (`docs/features/session-lifecycle.md`).
  """
  @spec follow_up(t(), String.t(), keyword()) :: :ok | {:error, send_error()}
  def follow_up(%__MODULE__{} = session, text, opts \\ []) when is_binary(text) and is_list(opts),
    do: send_user(session, :follow_up, text, opts)

  @doc """
  Compacts the context as a turn with no user message, by the provider or the
  Compaction plugin. A running turn aborts first, and a second compaction
  before the end gives `{:error, :turn_running}`
  (`docs/features/summary-compaction.md`).
  """
  @spec compact(t(), String.t()) ::
          :ok | {:error, :turn_running | :text_too_large | :invalid_utf8 | :session_not_found}
  def compact(%__MODULE__{} = session, instructions \\ "") when is_binary(instructions),
    do: send_text(session, {:compact, instructions}, instructions)

  defp send_user(session, op, text, opts),
    do:
      with({:ok, origin} <- Input.origin(opts), do: send_text(session, {op, text, origin}, text))

  defp send_text(session, request, text),
    do: with(:ok <- Input.text(text), do: call(session, request))

  @doc """
  Switches the session's model. The ref is parsed and its provider resolved
  like the `:model` of `start/2`, and each error is a `t:model_error/0`: the
  model stays as it was. The switch goes out as a `:model_change` event and
  is written to the session file. A running turn keeps the model it started
  with (`docs/features/output-limit.md`).
  """
  @spec set_model(t(), String.t()) :: :ok | {:error, model_error() | :session_not_found}
  def set_model(%__MODULE__{core: core} = session, string) when is_binary(string) do
    with {:ok, {ref, provider}} <- Input.model(core, string) do
      call(session, {:set_model, ref, provider, Input.limit_supported?(core, provider)})
    end
  rescue
    # The plugin table is gone with its Core, and so is the session.
    ArgumentError -> {:error, :session_not_found}
  end

  @doc """
  Aborts the turn, or the wait after it. A running turn ends at once as
  `:aborted`, each open tool call gets an `aborted` error result, and queued
  texts go back in a `:queue_dropped` event before `turn_end`; the call waits
  until the end of the wait. An unconfirmed resource release returns `:ok`
  and gives a `:notice` (`docs/features/session-lifecycle.md`, "Turn end",
  "The wait").
  """
  @spec abort(t()) :: :ok | {:error, :session_not_found}
  def abort(%__MODULE__{} = session), do: call(session, :abort, :infinity)

  defp call(session, request, timeout \\ @call_timeout_ms),
    do: Call.call(session, request, timeout)
end
