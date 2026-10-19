defmodule Helyx.Provider.ClaudeCode.Program do
  @moduledoc false
  # The `claude` program of `Helyx.Provider.ClaudeCode`: its flags, its
  # prompt, its harness session id, and its replacement
  # (`docs/features/provider-parity.md`). The functions take and give the
  # provider state.

  alias Helyx.HarnessIO
  alias Helyx.Provider.ClaudeCode
  alias Helyx.Provider.ClaudeCode.{Mcp, Meter, Replay, State}

  # The `=` form keeps a value that starts with a dash a value (#478).
  # `--tools=` turns off every tool of the program, `--setting-sources=`
  # and `--strict-mcp-config` load none of the user's config, and the empty
  # `--system-prompt=` with the snapshot off lets the `initialize` prompt
  # replace the program's own, also on a resume
  # (`docs/research/provider-parity.md`). The stored id has their digest.
  @flags ~w(--output-format stream-json --verbose --include-partial-messages --input-format
            stream-json --permission-mode bypassPermissions --tools= --setting-sources=
            --strict-mcp-config --system-prompt= --system-prompt-snapshot=off)

  # The state fields of the options of `init/3` (`HarnessIO.options/1`),
  # and the harness session of the stored id, or nil.
  def resume(opts) do
    with {:ok, options} <- HarnessIO.options(opts),
         do: {:ok, options, HarnessIO.resumable(opts[:resume_id], @flags)}
  end

  def stored_id(id), do: HarnessIO.session_id(id, @flags)

  # The resume id event of a fresh harness session; none with no stored
  # state, which has nothing to resume.
  def resume_events(%State{persist?: false}, _turn_id, _cut), do: []

  def resume_events(state, turn_id, cut),
    do: [{:event, turn_id, {:resume_id, stored_id(state.session_id), cut}}]

  # The error of a compaction with no program of its own: a fresh harness
  # session has no history yet, and one with no stored state cannot be
  # resumed in the program of a compaction (docs/features/harness-no-state.md).
  def no_compaction(%State{persist?: false}),
    do: HarnessIO.compaction_failed(ClaudeCode.id(), "no stored state to compact")

  def no_compaction(_state), do: HarnessIO.no_history(ClaudeCode.id())

  # A program with the prompt `system` and `commands?`: the running one, or
  # one in its place that resumes its harness session once the running one
  # ended.
  def ensure(%State{port: port, system: system, commands?: commands?} = state, system, commands?)
      when port != nil,
      do: state

  # A harness session with no stored state cannot be resumed: a fresh one
  # with a new meter takes its place, and its turn gets the replay.
  def ensure(%State{port: nil, persist?: false, sent?: true} = state, system, commands?) do
    meter = Meter.start(nil, state.meter.config_window)
    start(replace(state, meter: meter, commands?: commands?), system)
  end

  def ensure(%State{port: nil} = state, system, commands?) do
    resume = if state.sent?, do: state.session_id, else: state.resume
    start(replace(state, resume: resume, meter: state.meter, commands?: commands?), system)
  end

  def ensure(state, system, commands?) do
    case HarnessIO.finish(state) do
      :ok -> ensure(%{state | port: nil}, system, commands?)
      {:error, _reason} = error -> %{state | terminal: error}
    end
  end

  # A new state in place of the running program's, with that program
  # stopped.
  def replace(state, fields) do
    if state.port, do: HarnessIO.stop(state)

    keep = [
      exe: state.exe,
      model: state.model,
      cwd: state.cwd,
      tools: state.tools,
      handles: state.handles,
      persist?: state.persist?,
      env: state.env
    ]

    struct!(State, keep ++ fields)
  end

  # The prompt is the first line on stdin, so its size has the stdin bound
  # of the watchdog and no argv bound. A program that did not start has no
  # port: `Helyx.Watchdog.start/4` closed it.
  #
  # `--disable-slash-commands` keeps a user line from running a command or
  # a skill of the program. It also takes out `/compact`, so the program of
  # a compaction runs without it (`docs/research/provider-parity.md`). It
  # is a flag of one launch, so it is not in the stored id's digest; nor is
  # `--no-session-persistence`, whose harness session has no stored id.
  def start(state, system) do
    id = state.resume || uuid()
    session = if state.resume, do: "--resume=" <> id, else: "--session-id=" <> id
    commands = if state.commands?, do: [], else: ["--disable-slash-commands"]
    persist = if state.persist?, do: [], else: ["--no-session-persistence"]
    tail = ["--model=" <> state.model, session, "--mcp-config", Mcp.config()]
    flags = @flags ++ commands ++ persist ++ tail

    state =
      HarnessIO.launch(state.exe, flags, state.cwd, %{state | session_id: id, system: system})

    request = %{subtype: "initialize", systemPrompt: system}
    line = %{type: "control_request", request_id: "initialize", request: request}
    if state.port, do: HarnessIO.write(state, Replay.line(line))
    state
  end

  # A random version 4 UUID: `--session-id` takes only a UUID.
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
