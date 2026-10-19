defmodule Helyx.Provider.ClaudeCode.Program do
  @moduledoc false
  # The `claude` program of `Helyx.Provider.ClaudeCode`: its flags, its
  # prompt, its harness session id, and its replacement
  # (`docs/features/provider-parity.md`). The functions take and give the
  # provider state.

  alias Helyx.HarnessIO
  alias Helyx.Provider.ClaudeCode.{Mcp, Replay, State}

  # The `=` form keeps a value that starts with a dash a value (#478).
  # `--tools=` turns off every tool of the program, `--setting-sources=`
  # and `--strict-mcp-config` load none of the user's config, and the empty
  # `--system-prompt=` with the snapshot off lets the `initialize` prompt
  # replace the program's own, also on a resume
  # (`docs/research/provider-parity.md`). The stored id has their digest.
  @flags ~w(--output-format stream-json --verbose --include-partial-messages --input-format
            stream-json --permission-mode bypassPermissions --tools= --setting-sources=
            --strict-mcp-config --system-prompt= --system-prompt-snapshot=off)

  # The harness session of a stored id, or nil.
  def resumable(stored), do: HarnessIO.resumable(stored, @flags)

  def stored_id(id), do: HarnessIO.session_id(id, @flags)

  # A program with the prompt `system` and `commands?`: the running one, or
  # one in its place that resumes its harness session once the running one
  # ended.
  def ensure(%State{port: port, system: system, commands?: commands?} = state, system, commands?)
      when port != nil,
      do: state

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
      handles: state.handles
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
  # is a flag of one launch, so it is not in the stored id's digest.
  def start(state, system) do
    id = state.resume || uuid()
    session = if state.resume, do: "--resume=" <> id, else: "--session-id=" <> id
    commands = if state.commands?, do: [], else: ["--disable-slash-commands"]

    flags =
      @flags ++ commands ++ ["--model=" <> state.model, session, "--mcp-config", Mcp.config()]

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
