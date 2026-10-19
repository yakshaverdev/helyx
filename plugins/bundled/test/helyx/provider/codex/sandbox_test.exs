defmodule Helyx.Provider.Codex.SandboxTest do
  # The options `codex_sandbox` and `codex_approval_policy`
  # (docs/features/long-lived-harness.md, "Sandbox and approvals").
  use ExUnit.Case, async: true

  import Helyx.Test.CodexFake
  import Helyx.Test.HarnessDriver

  alias Helyx.Message
  alias Helyx.Provider.Codex

  @moduletag :tmp_dir
  setup {Helyx.Test.CodexFake, :setup_fake}

  defp run(state, system, text) do
    context = %Helyx.Context{system: system, messages: [Message.user(text)]}
    {_from, actions, state} = ask(state, {:turn, "t1", context})
    {_actions, state} = pump(Codex, state, actions, &turn_ended?/1)
    state
  end

  defp trust(request),
    do: Map.take(request["params"], ~w(sandbox approvalPolicy approvalsReviewer))

  test "the thread start and the resume of a prompt change send the values",
       %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    initialize(bin, 2)
    on(bin, 2, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])
    on(bin, 2, "turn/start", turn(tid(), reply(tid(), "two")))

    opts = [codex_sandbox: "read-only", codex_approval_policy: "on-request"]
    {:ok, state} = connect(work, opts)
    close(run(run(state, "A", "x"), "B", "y"))

    asked = %{
      "sandbox" => "read-only",
      "approvalPolicy" => "on-request",
      "approvalsReviewer" => "user"
    }

    assert runs(bin) == "2"
    assert trust(request(bin, 1, "thread/start")) == asked
    assert trust(request(bin, 2, "thread/resume")) == asked
  end

  test "a stored id resumes with the values of the new start", %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/resume", [j(%{id: "@", result: %{thread: thread(tid())}})])
    on(bin, 1, "turn/start", turn(tid(), reply(tid(), "back")))

    opts = [
      resume_id: stored(tid()),
      codex_sandbox: "read-only",
      codex_approval_policy: "untrusted"
    ]

    {:ok, state} = connect(work, opts)
    close(run(state, "A", "x"))

    assert trust(request(bin, 1, "thread/resume")) == %{
             "sandbox" => "read-only",
             "approvalPolicy" => "untrusted",
             "approvalsReviewer" => "user"
           }
  end

  test "Claude Code ignores both options", %{work: work} do
    opts = [cwd: work, codex_sandbox: "bogus", codex_approval_policy: :bogus]
    assert {:ok, _state} = Helyx.Provider.ClaudeCode.init("haiku", [], opts)
  end

  test "the defaults are the trust of the bash tool", %{bin: bin, work: work} do
    fresh(bin, 1, tid(), reply(tid(), "one"))
    {:ok, state} = connect(work)
    close(run(state, "A", "x"))

    assert trust(request(bin, 1, "thread/start")) == %{
             "sandbox" => "danger-full-access",
             "approvalPolicy" => "never",
             "approvalsReviewer" => "user"
           }
  end

  test "each string of the schema is taken, and any other value fails the init",
       %{work: work} do
    for sandbox <- ~w(read-only workspace-write danger-full-access),
        policy <- ~w(untrusted on-request never) do
      opts = [codex_sandbox: sandbox, codex_approval_policy: policy]
      assert {:ok, options} = Codex.Program.options(opts)

      assert options[:trust] == %{
               sandbox: sandbox,
               approvalPolicy: policy,
               approvalsReviewer: "user"
             }
    end

    granular = %{"granular" => %{"mcp_elicitations" => false, "rules" => false}}

    for bad <- [nil, :read_only, "READ-ONLY", "read-only ", "", granular] do
      assert connect(work, codex_sandbox: bad) == {:error, {:invalid_option, :codex_sandbox}}

      assert connect(work, codex_approval_policy: bad) ==
               {:error, {:invalid_option, :codex_approval_policy}}
    end
  end
end
