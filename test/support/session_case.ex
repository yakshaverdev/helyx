defmodule Helyx.Test.SessionCase do
  @moduledoc false
  # The setup and the helpers of the session test modules. The tests are in
  # several async modules, so that ExUnit runs them in parallel (#295).
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Helyx.Session

  @plugins [
    Helyx.Test.Provider,
    Helyx.Test.ProviderOther,
    Helyx.Test.Connected,
    Helyx.Test.Tool.Upcase,
    Helyx.Test.Tool.Kill,
    Helyx.Test.Tool.Slow,
    Helyx.Test.Tool.Binary,
    Helyx.Test.Tool.Hold
  ]

  # The setup: a Core with the test plugins.
  def start_core(%{} = _context), do: %{core: start_core(@plugins)}

  # A Core with its own name and child id, so that a test can start more
  # than one.
  def start_core(plugins) do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: plugins}, id: core)
    core
  end

  def final_text(events), do: Helyx.Message.text(final_message(events))

  # The outcome of the turn that ends `events`; at `done`, the stop reason
  # of its last message.
  def stop_reason(events) do
    case List.last(events).data do
      %{outcome: :done} -> final_message(events).stop_reason
      %{outcome: outcome} -> outcome
    end
  end

  def final_message(events), do: List.last(Helyx.Test.Events.messages(events))

  # The model "test/gate.<name>" with the test process registered as <name>:
  # each turn sends {:waiting, pid} and waits for :go.
  def gated_model, do: "test/gate." <> Helyx.Test.Gate.open()

  # A second sessions folder that holds a hard link of the file of session
  # `id` in `dir`: a session open from each folder writes the one file, and
  # each has its own lock (docs/features/session-lock.md). Returns the folder.
  def link_session(dir, id) do
    [path] = Path.wildcard(Path.join([dir, "*", id <> ".jsonl"]))
    other = Path.join(dir, "linked")
    target = Path.join([other, Path.basename(Path.dirname(path)), Path.basename(path)])
    File.mkdir_p!(Path.dirname(target))
    File.ln!(path, target)
    other
  end

  # Stops the session, waits until it is down, then until the Registry
  # drops its entry, which the Registry does after the exit, and until the
  # lock of its file is free: perl exits after the session (#670).
  def stop_session(session, stop) do
    pid = Session.pid(session)
    file = :sys.get_state(pid).file
    ref = Process.monitor(pid)
    stop.(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    registry = Helyx.Core.sessions_registry(session.core)
    await(fn -> Registry.lookup(registry, session.id) == [] end, "the registry entry to free")
    if file, do: Helyx.Test.SessionFile.await_lock_free(file.path)
  end

  # The messages in the mailbox now, in order.
  def mailbox, do: elem(Process.info(self(), :messages), 1)

  # Polls a condition every 10 ms, by default for the cap of a wait. Only
  # for a state that no process tells by a message: a Registry entry, a
  # mailbox length, memory.
  def await(condition, what, tries \\ div(Helyx.Test.Events.wait_ms(), 10))
  def await(_condition, what, 0), do: flunk("timed out waiting for #{what}")

  def await(condition, what, tries) do
    unless condition.() do
      Process.sleep(10)
      await(condition, what, tries - 1)
    end
  end

  # Waits until the mailbox of `pid` holds its `:DOWN` of `ended`. One exit
  # gives each monitor its own `:DOWN`, with no order between them, so the
  # `:DOWN` of the test says nothing of the one of `pid` (#605, #670).
  def await_down(pid, ended, what) do
    await(
      fn ->
        {:messages, messages} = Process.info(pid, :messages)
        Enum.any?(messages, &match?({:DOWN, _, :process, ^ended, _}, &1))
      end,
      what
    )
  end

  def user_texts(events) do
    for %{type: :message_end, data: %{message: %Helyx.Message{role: :user} = m}} <- events,
        do: Helyx.Message.text(m)
  end

  def queue_counts(events) do
    for %{type: :queue_update, data: data} <- events, do: data
  end
end
