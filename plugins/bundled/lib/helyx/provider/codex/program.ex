defmodule Helyx.Provider.Codex.Program do
  @moduledoc false
  # The `codex app-server` program of `Helyx.Provider.Codex` and the open
  # of its thread: the flags, the thread's prompt and tools, the stored id,
  # and the program that takes the place of one with another prompt
  # (`docs/features/provider-parity.md`).

  import Helyx.Provider.Codex.Wire, only: [reply: 3, rpc: 3]

  alias Helyx.HarnessIO
  alias Helyx.Provider.Codex.{State, Tools}

  # The string values of `SandboxMode` and `AskForApproval` in the schema
  # of codex 0.163.0 (research note, "Sandbox and approval values").
  @sandboxes ~w(read-only workspace-write danger-full-access)
  @approval_policies ~w(untrusted on-request never)

  # The shell is off, and so is the user's config that the program lets go
  # (`docs/research/provider-parity.md`). The stored id has their digest.
  @args ~w(app-server --disable shell_tool --disable unified_exec --disable apps --disable plugins
           --disable hooks --disable goals --disable view_image --disable image_generation
           -c project_doc_max_bytes=0 -c web_search="disabled" -c skills.include_instructions=false
           -c skills.bundled.enabled=false -c include_permissions_instructions=false
           -c include_apps_instructions=false)

  # The options of `init/3`: those of `HarnessIO.options/1`, and the trust
  # of the thread from `codex_sandbox` and `codex_approval_policy`. The
  # reviewer `user` sends each approval request to Helyx, not to one that
  # the user's config names (docs/features/long-lived-harness.md, "Sandbox
  # and approvals").
  def options(opts) do
    with {:ok, options} <- HarnessIO.options(opts),
         {:ok, sandbox} <- pick(opts, :codex_sandbox, "danger-full-access", @sandboxes),
         {:ok, policy} <- pick(opts, :codex_approval_policy, "never", @approval_policies) do
      trust = %{sandbox: sandbox, approvalPolicy: policy, approvalsReviewer: "user"}
      {:ok, [trust: trust] ++ options}
    end
  end

  defp pick(opts, key, default, values) do
    value = Keyword.get(opts, key, default)
    if value in values, do: {:ok, value}, else: {:error, {:invalid_option, key}}
  end

  # The thread of a stored id, or nil: the program fixes the flags and the
  # tools at the start of a thread.
  def resumable(stored, specs), do: HarnessIO.resumable(stored, fixed(specs))

  def stored_id(thread, specs), do: HarnessIO.session_id(thread, fixed(specs))

  # The resume id of a fresh thread; none for an ephemeral thread, which
  # has nothing to resume (docs/features/harness-no-state.md).
  def resume_events(%State{persist?: false}, _cut), do: []

  def resume_events(state, cut),
    do: [{:resume_id, stored_id(state.thread, state.tools.specs), cut}]

  defp fixed(specs), do: [@args, Tools.specs(specs)]

  # The program, with its `initialize` sent.
  def launch(state) do
    state = HarnessIO.launch(state.exe, @args, state.cwd, state)

    if state.port,
      do: rpc(state, "initialize", Tools.initialize_params(state.tools.specs)),
      else: state
  end

  # A loaded thread keeps its prompt on `thread/resume`, and a new program
  # takes the new one (research note): a new program takes the place of
  # the running one and resumes the thread at its `initialize` answer. The
  # steers without an answer and the child threads end with the old
  # program, which ends before the new one starts.
  def replace(state, system) do
    state =
      Enum.reduce(state.asked, %{state | asked: %{}}, fn {_id, from}, s ->
        reply(s, from, {:error, :restarted})
      end)

    # An ephemeral thread cannot be resumed: a fresh one gets the replay.
    resume = if state.persist?, do: state.thread
    fields = [port: nil, thread: nil, resume: resume, system: system, buffer: [], size: 0]

    with :ok <- HarnessIO.finish(state),
         %State{terminal: nil} = state <-
           launch(struct!(state, fields ++ [due: %{}, agents: %{}])) do
      state
    else
      {:error, reason} -> failed(state, reason)
      %State{terminal: {:error, reason}} = state -> failed(state, reason)
    end
  end

  defp failed(state, reason), do: reply(%{state | from: nil}, state.from, {:error, reason})

  def open_thread(%State{resume: nil, tools: %Tools{specs: []}} = state),
    do: rpc(state, "thread/start", params(state))

  def open_thread(%State{resume: nil} = state),
    do:
      rpc(
        state,
        "thread/start",
        Map.put(params(state), :dynamicTools, Tools.specs(state.tools.specs))
      )

  def open_thread(state),
    do:
      rpc(
        state,
        "thread/resume",
        Map.merge(params(state), %{threadId: state.resume, excludeTurns: true})
      )

  # A thread with no stored state is ephemeral. It is never resumed, so
  # `thread/resume` never gets the option.
  defp params(state) do
    params =
      Map.merge(state.trust, %{model: state.model, cwd: state.cwd, baseInstructions: state.system})

    if state.persist?, do: params, else: Map.put(params, :ephemeral, true)
  end
end
