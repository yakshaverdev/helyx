defmodule Helyx.Provider.Codex.Program do
  @moduledoc false
  # The `codex app-server` program of `Helyx.Provider.Codex` and the open
  # of its thread: the flags, the thread's prompt and tools, the stored id,
  # and the program that takes the place of one with another prompt
  # (`docs/features/provider-parity.md`).

  import Helyx.Provider.Codex.Wire, only: [reply: 3, rpc: 3]

  alias Helyx.HarnessIO
  alias Helyx.Provider.Codex.{State, Tools}

  @trust %{approvalPolicy: "never", sandbox: "danger-full-access"}

  # The shell is off, and so is the user's config that the program lets go
  # (`docs/research/provider-parity.md`). The stored id has their digest.
  @args ~w(app-server --disable shell_tool --disable unified_exec --disable apps --disable plugins
           --disable hooks --disable goals --disable view_image --disable image_generation
           -c project_doc_max_bytes=0 -c web_search="disabled" -c skills.include_instructions=false
           -c skills.bundled.enabled=false -c include_permissions_instructions=false
           -c include_apps_instructions=false)

  # The thread of a stored id, or nil: the program fixes the flags and the
  # tools at the start of a thread.
  def resumable(stored, specs), do: HarnessIO.resumable(stored, fixed(specs))

  def stored_id(thread, specs), do: HarnessIO.session_id(thread, fixed(specs))

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

    fields = [port: nil, thread: nil, resume: state.thread, system: system, buffer: [], size: 0]

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

  defp params(state),
    do: Map.merge(@trust, %{model: state.model, cwd: state.cwd, baseInstructions: state.system})
end
