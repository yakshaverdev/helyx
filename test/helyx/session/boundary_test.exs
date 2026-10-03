defmodule Helyx.Session.BoundaryTest do
  # Tool specs, tool checks, and the cwd at the session boundary, model
  # switches by set_model/2, and the start errors that a client sees.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

  describe "tool specs at the session boundary (#142)" do
    # One bad test tool per rule of `Helyx.Tool.specs/1`, and one per
    # failure class of a spec callback (raise, throw, exit), with the label
    # the error gives. Each row holds the quoted callback bodies.
    @empty Macro.escape(%{})
    @bad_specs [
      {Helyx.SessionTest.EmptyName, "", "d", @empty, "Helyx.SessionTest.EmptyName"},
      {Helyx.SessionTest.AtomName, :bad, "d", @empty, "Helyx.SessionTest.AtomName"},
      {Helyx.SessionTest.BytesName, <<"b", 255>>, "d", @empty, "Helyx.SessionTest.BytesName"},
      {Helyx.SessionTest.NilDesc, "t", nil, @empty, "t"},
      {Helyx.SessionTest.BytesDesc, "t", <<"d", 255>>, @empty, "t"},
      {Helyx.SessionTest.ListParams, "t", "d", [], "t"},
      {Helyx.SessionTest.AtomKeys, "t", "d", Macro.escape(%{type: "object"}), "t"},
      {Helyx.SessionTest.TupleParams, "t", "d", Macro.escape(%{"type" => {:object}}), "t"},
      {Helyx.SessionTest.BytesParams, "t", "d", Macro.escape(%{"type" => <<255>>}), "t"},
      {Helyx.SessionTest.ThrowingEncoder, "t", "d",
       Macro.escape(%{"type" => %Helyx.Test.FailingJSON{kind: :throw}}),
       "Helyx.SessionTest.ThrowingEncoder"},
      {Helyx.SessionTest.ExitingEncoder, "t", "d",
       Macro.escape(%{"type" => %Helyx.Test.FailingJSON{kind: :exit}}),
       "Helyx.SessionTest.ExitingEncoder"},
      {Helyx.SessionTest.RaisingName, quote(do: raise("boom")), "d", @empty,
       "Helyx.SessionTest.RaisingName"},
      {Helyx.SessionTest.ThrowingDescription, "t", quote(do: throw(:boom)), @empty,
       "Helyx.SessionTest.ThrowingDescription"},
      {Helyx.SessionTest.ExitingParameters, "t", "d", quote(do: exit(:boom)),
       "Helyx.SessionTest.ExitingParameters"}
    ]

    for {module, name, description, parameters, _label} <- @bad_specs do
      defmodule module do
        @moduledoc false
        @behaviour Helyx.Tool

        @impl true
        def name, do: unquote(name)
        @impl true
        def description, do: unquote(description)
        @impl true
        def parameters, do: unquote(parameters)
        @impl true
        def run(_args, _cwd), do: {:ok, ""}
      end
    end

    defmodule Counted do
      @moduledoc false
      # Each spec callback tells the test process that it ran.
      @behaviour Helyx.Tool

      defp ran(callback) do
        send(:persistent_term.get({__MODULE__, :observer}), {:spec_callback, callback})
      end

      @impl true
      def name, do: tap("counted", fn _ -> ran(:name) end)
      @impl true
      def description, do: tap("Counts.", fn _ -> ran(:description) end)
      @impl true
      def parameters, do: tap(%{"type" => "object"}, fn _ -> ran(:parameters) end)
      @impl true
      def run(_args, _cwd), do: {:ok, ""}
    end

    @tag :tmp_dir
    test "start rejects each bad or failing spec, names the tool, and makes nothing", %{
      tmp_dir: dir
    } do
      for {module, _name, _description, _parameters, label} <- @bad_specs do
        core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, module])

        assert {:error, {:bad_tool_spec, ^label}} =
                 Session.start(core, model: "test/ok", sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
      end

      assert File.ls!(dir) == []
    end

    @tag :tmp_dir
    test "resume rejects a bad or failing spec before it reads or repairs the file",
         %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      GenServer.stop(Session.pid(session))

      # A torn last line, which a resume would repair.
      File.write!(path, ~s({"type":"mess), [:append])
      before = File.read!(path)

      for {module, _name, _description, _parameters, label} <- @bad_specs do
        bad = start_core([Helyx.Test.Provider, module])
        assert {:error, {:bad_tool_spec, ^label}} = Session.resume(bad, sessions_dir: dir)
        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(bad)).active == 0
      end

      assert File.read!(path) == before
    end

    test "the spec callbacks run once per session, not per provider call" do
      :persistent_term.put({Counted, :observer}, self())
      on_exit(fn -> :persistent_term.erase({Counted, :observer}) end)
      core = start_core([Helyx.Test.Provider, Counted])
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)

      for text <- ["one", "two"] do
        :ok = Session.prompt(session, text)
        assert stop_reason(collect_until(:agent_end)) == :end_turn
      end

      for callback <- [:name, :description, :parameters],
          do: assert_received({:spec_callback, ^callback})

      refute_received {:spec_callback, _}
    end
  end

  describe "tool checks at the session boundary (#150)" do
    # One test tool per failing `check/0`: the quoted body, and the reason
    # the error gives.
    @bad_checks [
      {Helyx.SessionTest.CheckRaises, quote(do: raise("boom")),
       "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckThrows, quote(do: throw(:boom)),
       "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckExits, quote(do: exit(:boom)), "check/0 raised, threw, or exited"},
      {Helyx.SessionTest.CheckBadValue, :yes, "check/0 returned a bad value"},
      {Helyx.SessionTest.CheckAtomReason, {:error, :enoent}, "check/0 returned a bad value"},
      {Helyx.SessionTest.CheckBytesReason, {:error, <<"x", 255>>}, "check/0 returned a bad value"}
    ]

    for {module, body, _reason} <- @bad_checks do
      defmodule module do
        @moduledoc false
        @behaviour Helyx.Tool

        @impl true
        def name, do: "checked"
        @impl true
        def description, do: "d"
        @impl true
        def parameters, do: %{}
        @impl true
        def run(_args, _cwd), do: {:ok, ""}
        @impl true
        def check, do: unquote(body)
      end
    end

    @cases [
      {Helyx.Test.Tool.Unavailable, "unavailable", "the frob is missing"}
      | for({module, _body, reason} <- @bad_checks, do: {module, "checked", reason})
    ]

    @tag :tmp_dir
    test "start rejects a failed check, names the tool, and makes nothing", %{tmp_dir: dir} do
      for {module, name, reason} <- @cases do
        core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Upcase, module])

        assert {:error, {:tool_unavailable, ^name, ^reason}} =
                 Session.start(core, model: "test/ok", sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
      end

      assert File.ls!(dir) == []
    end

    test "the check runs before the model ref resolves" do
      core = start_core([Helyx.Test.Provider, Helyx.Test.Tool.Unavailable])

      assert {:error, {:tool_unavailable, "unavailable", _reason}} =
               Session.start(core, model: "nope/x")
    end

    @tag :tmp_dir
    test "resume rejects a failed check before it reads or repairs the file",
         %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      GenServer.stop(Session.pid(session))

      # A torn last line, which a resume would repair.
      File.write!(path, ~s({"type":"mess), [:append])
      before = File.read!(path)

      for {module, name, reason} <- @cases do
        bad = start_core([Helyx.Test.Provider, module])

        assert {:error, {:tool_unavailable, ^name, ^reason}} =
                 Session.resume(bad, sessions_dir: dir)

        assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(bad)).active == 0
      end

      assert File.read!(path) == before
    end
  end

  describe "cwd at the session boundary (#140)" do
    @bad_cwds [:repo, ~c"/repo", <<"/repo", 255>>, "/re\0po"]

    @tag :tmp_dir
    test "start rejects a cwd that is not a UTF-8 string without a NUL byte, and makes nothing",
         %{core: core, tmp_dir: dir} do
      for cwd <- @bad_cwds do
        assert {:error, :invalid_cwd} =
                 Session.start(core, model: "test/ok", cwd: cwd, sessions_dir: dir)
      end

      assert File.ls!(dir) == []
      assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
    end

    @tag :tmp_dir
    test "resume rejects the same cwds before it reads the sessions dir",
         %{core: core, tmp_dir: dir} do
      for cwd <- @bad_cwds do
        assert {:error, :invalid_cwd} = Session.resume(core, cwd: cwd, sessions_dir: dir)
      end

      assert File.ls!(dir) == []
      assert DynamicSupervisor.count_children(Helyx.Core.session_supervisor(core)).active == 0
    end
  end

  @tag :tmp_dir
  test "a working directory that is gone gives an error result", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/loop", cwd: Path.join(dir, "gone"))
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) =~ "working directory does not exist"
  end

  describe "set_model/2" do
    test "the next turn uses the new provider, and a switch back works", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/ok")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "one")
      first = collect_until(:agent_end)
      assert final_text(first) == "ok"

      assert :ok = Session.set_model(session, "other/any")
      assert_receive {:helyx_event, %Event{type: :model_change} = change}
      assert change.data == %{model: "other/any"}
      assert change.turn_id == nil
      assert change.seq == List.last(first).seq + 1
      refute_received {:helyx_event, _}
      assert GenServer.call(Session.pid(session), :snapshot).model == "other/any"

      :ok = Session.prompt(session, "two")
      second = collect_until(:agent_end)
      assert final_text(second) == "from other"
      assert Enum.find(second, &(&1.type == :turn_end)).data.message.model == "other/any"
      assert hd(second).seq == change.seq + 1

      assert :ok = Session.set_model(session, "test/ok")
      assert_receive {:helyx_event, %Event{type: :model_change}}
      :ok = Session.prompt(session, "three")
      assert final_text(collect_until(:agent_end)) == "ok"
    end

    @tag :tmp_dir
    test "a rejected ref leaves the model, the file, and the event stream unchanged", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      before = File.read!(path)

      assert {:error, {:unknown_provider, "nope"}} = Session.set_model(session, "nope/model")
      assert {:error, {:invalid_model_ref, "test"}} = Session.set_model(session, "test")
      assert {:error, {:invalid_model_ref, _}} = Session.set_model(session, <<"test/", 255>>)

      assert GenServer.call(Session.pid(session), :snapshot).model == "test/ok"
      assert File.read!(path) == before
      refute_received {:helyx_event, _}
    end

    @tag :tmp_dir
    test "the switch is a model change entry and survives resume", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      :ok = Session.set_model(session, "other/any")

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))

      entries =
        path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert [%{"type" => "session", "id" => id}, %{"type" => "model_change"} = entry] = entries
      assert %{"model" => "other/any", "parent_id" => ^id} = entry

      stop_session(session, &GenServer.stop/1)

      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      assert GenServer.call(Session.pid(resumed), :snapshot).model == "other/any"
      {:ok, _} = Session.subscribe(resumed)
      :ok = Session.prompt(resumed, "hello")
      assert final_text(collect_until(:agent_end)) == "from other"
    end

    test "a switch during a turn takes effect on the next turn", %{core: core} do
      {:ok, session} = Session.start(core, model: "test/steer")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
      :ok = Session.set_model(session, "other/any")
      :ok = Session.follow_up(session, "again")
      assert_receive {:helyx_event, %Event{type: :model_change, turn_id: nil}}

      # The running turn makes its second provider call on the old model.
      running = collect_until(:agent_end)
      assert final_text(running) == "hello"
      assert Enum.find(running, &(&1.type == :turn_end)).data.message.model == "test/steer"
      assert final_text(collect_until(:agent_end)) == "from other"
    end

    @tag :tmp_dir
    test "a switch to the current model is accepted and recorded like any other", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)

      assert :ok = Session.set_model(session, "test/ok")
      assert_receive {:helyx_event, %Event{type: :model_change, data: %{model: "test/ok"}}}
      refute_received {:helyx_event, _}

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert [_header, change] = Enum.map(lines, &JSON.decode!/1)
      assert %{"type" => "model_change", "model" => "test/ok"} = change
    end

    test "a ref outside the bounds is rejected at start too", %{core: core} do
      long = "test/" <> String.duplicate("m", 252)
      assert {:error, {:invalid_model_ref, ^long}} = Session.start(core, model: long)
      assert {:error, {:invalid_model_ref, "test/a b"}} = Session.start(core, model: "test/a b")
    end

    @tag :tmp_dir
    test "a model change entry for the largest ref stays under the stated size", %{
      core: core,
      tmp_dir: dir
    } do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      # 256 bytes, every model byte doubled by the JSON encoding.
      :ok = Session.set_model(session, "test/" <> String.duplicate("\"", 251))

      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      [_header, change] = path |> File.read!() |> String.split("\n", trim: true)
      assert byte_size(change) <= 660
    end

    @tag :tmp_dir
    test "a switch still works when the file cannot be written", %{core: core, tmp_dir: dir} do
      {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
      {:ok, _} = Session.subscribe(session)
      [path] = Path.wildcard(Path.join(dir, "**/#{session.id}.jsonl"))
      header = File.read!(path)
      File.rm!(path)
      File.mkdir!(path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Session.set_model(session, "other/any")
        end)

      assert log =~ "persistence off"
      assert_receive {:helyx_event, %Event{type: :notice, turn_id: nil}}
      assert_receive {:helyx_event, %Event{type: :model_change, turn_id: nil}}
      assert GenServer.call(Session.pid(session), :snapshot).model == "other/any"

      # Persistence stays off: with the file back, a turn writes nothing.
      File.rmdir!(path)
      File.write!(path, header)
      :ok = Session.prompt(session, "hello")
      assert final_text(collect_until(:agent_end)) == "from other"
      assert File.read!(path) == header
    end
  end
end
