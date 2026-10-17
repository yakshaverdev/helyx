defmodule Helyx.ModelInfo.CatalogTest do
  # `docs/features/usage-and-limits.md`, "The catalog", "Bounds", and
  # "Ownership". Not async: the refresh process has one registered name for
  # the node, and the tests change the `:model_catalog` app env. No test
  # fetches models.dev; a plug answers each fetch.
  use ExUnit.Case, async: false

  alias Helyx.ModelInfo
  alias Helyx.ModelInfo.Catalog

  @moduletag :tmp_dir

  @max_bytes 16 * 1024 * 1024
  @day_s 86_400
  # An event that must not happen (a fetch) would come within this margin:
  # the lookup spawns the refresh at once, and the plug answers with no wait.
  @load_ms 300

  @model "gpt-test"
  @prices %{"input" => 2, "output" => 10.0, "cache_read" => 0.5}
  @good %{
    "openai" => %{
      "models" => %{@model => %{"limit" => %{"context" => 400_000}, "cost" => @prices}}
    }
  }
  @newer put_in(@good, ["openai", "models", @model, "limit", "context"], 1_000)
  @set %{input: 2, output: 10.0, cache_read: 0.5}

  setup %{tmp_dir: dir} do
    env = Application.get_env(:helyx_plugins, :model_catalog)
    on_exit(fn -> Application.put_env(:helyx_plugins, :model_catalog, env) end)
    on_exit(fn -> new_node(dir) end)
    env(dir, url: nil)
    %{cache: Path.join(dir, "models.dev.json"), marker: Path.join(dir, "models.dev.attempt")}
  end

  defp env(dir, opts), do: Application.put_env(:helyx_plugins, :model_catalog, [dir: dir] ++ opts)

  # A refresh on: each fetch runs `reply` in the fetch Task, after it tells
  # the test.
  defp serve(dir, reply, opts \\ []) do
    test = self()

    plug = fn conn ->
      send(test, {:fetch, self(), conn})
      reply.(conn)
    end

    env(dir, [url: "http://models.test/api.json", req_options: [plug: plug]] ++ opts)
  end

  defp json(conn, status, body, headers \\ []) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  # Waits for the fetch, then for the end of the refresh process, and
  # returns the fetch Task and the request.
  defp await_refresh do
    assert_receive {:fetch, task, conn}
    await_end()
    {task, conn}
  end

  # The refresh holds its name until its write is done. It held the name
  # at the fetch, so no name now means that it has ended.
  defp await_end do
    if pid = Process.whereis(Catalog) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  # The data as a new node finds it: the first lookup loads it again.
  defp new_node(dir), do: :persistent_term.erase({Catalog, dir})

  defp window, do: info(@model).context_window

  defp info(model) do
    {:ok, info} = Catalog.lookup("openai", model)
    info
  end

  defp seed(cache, data), do: File.write!(cache, JSON.encode!(data))

  describe "the source rule" do
    test "config wins over the catalog, each value whole; a model not in the catalog gives nothing",
         %{cache: cache} do
      seed(cache, @good)
      prices = @set

      assert ModelInfo.lookup("codex", "openai", @model, %{}) ==
               {:ok, %ModelInfo{context_window: 400_000, prices: prices}}

      # A config price set with no cache price stays whole: the catalog's
      # cache price does not join it.
      config = %{("codex/" <> @model) => [context_window: 7, prices: [input: 1, output: 2]]}

      assert ModelInfo.lookup("codex", "openai", @model, config) ==
               {:ok, %ModelInfo{context_window: 7, prices: %{input: 1, output: 2}}}

      config = %{("codex/" <> @model) => [context_window: 7]}

      assert ModelInfo.lookup("codex", "openai", @model, config) ==
               {:ok, %ModelInfo{context_window: 7, prices: prices}}

      assert ModelInfo.lookup("codex", "openai", "other", %{}) == {:ok, %ModelInfo{}}
      # The catalog of another provider has no step for this one.
      assert ModelInfo.lookup("fake", nil, @model, %{}) == {:ok, %ModelInfo{}}
    end

    test "a bad :model_catalog value fails each lookup with its key", %{tmp_dir: dir} do
      bad = %{
        dir: ["", ~c"dir", nil, 5],
        url: [
          "",
          "models.dev/api.json",
          "ftp://models.dev/api.json",
          "https://",
          ~c"http://x",
          "https://x/" <> <<255>>,
          5
        ],
        req_options: [%{plug: nil}, [1], nil],
        fetch_ms: [0, -1, 86_400_001, 1.0, "60000", nil],
        other: [1]
      }

      for {key, values} <- bad, value <- values do
        Application.put_env(
          :helyx_plugins,
          :model_catalog,
          Keyword.merge([dir: dir, url: nil], [{key, value}])
        )

        # Also with no catalog id: each provider start checks it.
        for {provider, catalog} <- [{"codex", "openai"}, {"fake", nil}] do
          assert ModelInfo.lookup(provider, catalog, @model, %{}) ==
                   {:error, {:bad_config, [:model_catalog, key]}}
        end
      end

      for env <- [%{dir: dir}, "x", [:dir]] do
        Application.put_env(:helyx_plugins, :model_catalog, env)

        assert ModelInfo.lookup("codex", "openai", @model, %{}) ==
                 {:error, {:bad_config, [:model_catalog]}}
      end

      for good <- [
            [url: "https://models.dev/api.json", fetch_ms: 1, req_options: []],
            [url: nil, fetch_ms: 86_400_000]
          ] do
        # No refresh starts: "fake" has no catalog id.
        env(dir, good ++ [url: nil])
        assert {:ok, %ModelInfo{}} = ModelInfo.lookup("fake", nil, @model, %{})
      end

      Application.delete_env(:helyx_plugins, :model_catalog)
      assert {:ok, %ModelInfo{}} = ModelInfo.lookup("fake", nil, @model, %{})
    end

    test "tiers become {size, prices}", %{cache: cache} do
      tier = %{"input" => 4, "output" => 20, "tier" => %{"type" => "context", "size" => 200_000}}
      seed(cache, put_in(@good, ["openai", "models", @model, "cost", "tiers"], [tier]))

      assert info(@model).prices ==
               %{
                 input: 2,
                 output: 10.0,
                 cache_read: 0.5,
                 tiers: [{200_000, %{input: 4, output: 20}}]
               }
    end

    test "a window of 10^9 is kept and 10^9 + 1 is dropped; the usage passes Stream.check/1",
         %{cache: cache} do
      for {context, window} <- [{1_000_000_000, 1_000_000_000}, {1_000_000_001, nil}] do
        new_node(Path.dirname(cache))
        seed(cache, put_in(@good, ["openai", "models", @model, "limit", "context"], context))

        assert {:ok, info} = ModelInfo.lookup("codex", "openai", @model, %{})
        assert info.context_window == window
        usage = ModelInfo.price(%Helyx.Usage{input: 1_000_000_000, output: 1_000_000_000}, info)
        assert usage.context_window == window and usage.cost_kind == :list

        assert {:terminal, _} =
                 Helyx.Session.Stream.check({:done, %{stop_reason: :end_turn, usage: usage}})
      end
    end
  end

  describe "slim/1" do
    defp kept(entry),
      do: Catalog.slim(%{"openai" => %{"models" => %{"m" => entry}}})["openai"]["m"]

    test "a bad entry is dropped and the rest of the catalog is kept" do
      five = %{"limit" => %{"context" => 5}}
      long = String.duplicate("a", 256)
      # Two bytes for each "é": 256 bytes kept, 258 dropped.
      wide = String.duplicate("é", 128)

      api = %{
        "openai" => %{"models" => %{"ok" => five, "bad" => 1}},
        "anthropic" => %{"models" => %{long => five, wide => five, (wide <> "é") => five}},
        "opencode-go" => %{"models" => %{(long <> "a") => five, "" => five}},
        "opencode" => %{"models" => %{"ok" => five}}
      }

      entry = %ModelInfo{context_window: 5}

      assert Catalog.slim(api) == %{
               "openai" => %{"ok" => entry},
               "anthropic" => %{long => entry, wide => entry}
             }

      assert Catalog.slim(%{"opencode-go" => "not a map"}) == %{}
      assert Catalog.slim([]) == %{}
      assert Catalog.slim(%{"openai" => %{"models" => []}}) == %{}
    end

    test "the window: 1 to 10^9; 0 is unknown; a bad window leaves the price set" do
      for context <- [1, 1_000_000_000] do
        assert kept(%{"limit" => %{"context" => context}}) ==
                 %ModelInfo{context_window: context}
      end

      for context <- [0, -1, 1_000_000_001, 1.5, "5", nil] do
        assert kept(%{"limit" => %{"context" => context}, "cost" => @prices}) ==
                 %ModelInfo{prices: @set}
      end
    end

    test "each price from 0 to 10^6, input and output needed; a bad price set leaves the window" do
      for price <- [0, 0.0, 1_000_000, 1_000_000.0] do
        assert kept(%{"cost" => %{@prices | "input" => price}}).prices == %{@set | input: price}
      end

      window = %{"limit" => %{"context" => 5}}

      for cost <- [
            %{@prices | "input" => -0.01},
            %{@prices | "cache_read" => 1_000_000.01},
            %{@prices | "output" => "1"},
            Map.delete(@prices, "input"),
            Map.delete(@prices, "output"),
            "free"
          ] do
        assert kept(Map.put(window, "cost", cost)) == %ModelInfo{context_window: 5}
      end

      # Keys that Helyx has no price for are left out, not the set.
      assert kept(%{"cost" => Map.put(@prices, "input_audio", 1)}).prices == @set
    end

    test "tiers: at most 8, each of type context with a size of 1 to 10^9; else no price set" do
      tier = fn size ->
        %{"input" => 4, "output" => 20, "tier" => %{"type" => "context", "size" => size}}
      end

      tiers = for size <- 1..8, do: tier.(size * 1000)
      assert %{tiers: kept} = kept(%{"cost" => Map.put(@prices, "tiers", tiers)}).prices
      assert kept == for(size <- 1..8, do: {size * 1000, %{input: 4, output: 20}})
      assert kept(%{"cost" => Map.put(@prices, "tiers", [tier.(1), tier.(1_000_000_000)])})

      for bad <- [
            tiers ++ [tier.(9000)],
            [tier.(0)],
            [tier.(1_000_000_001)],
            [put_in(tier.(1000), ["tier", "type"], "time_of_day")],
            [Map.delete(tier.(1000), "tier")],
            [Map.delete(tier.(1000), "output")],
            [%{tier.(1000) | "input" => -1}],
            "tiers"
          ] do
        assert kept(%{"cost" => Map.put(@prices, "tiers", bad)}) == nil
      end
    end

    test "the snapshot holds the three catalog ids, and json/1 gives it back from its slim" do
      snapshot = File.read!(Application.app_dir(:helyx_plugins, "priv/models_dev.json"))
      data = JSON.decode!(snapshot)
      assert Map.keys(data) |> Enum.sort() == ~w(anthropic openai opencode-go)
      assert Catalog.json(Catalog.slim(data)) == data
    end
  end

  describe "load" do
    # The open of a FIFO with no writer blocks, and while it blocks the node
    # cannot open a file or a port. So a regression hangs this test.
    test "a cache path that is not a regular file gives the snapshot", %{cache: cache} do
      {_, 0} = System.cmd("mkfifo", [cache])
      assert window() == nil
    end

    test "the cache file, at most 16 MB, else the snapshot", %{tmp_dir: dir, cache: cache} do
      body = JSON.encode!(@good)

      # The model is not in the snapshot: nil means the snapshot.
      for {size, window} <- [{@max_bytes, 400_000}, {@max_bytes + 1, nil}] do
        new_node(dir)
        File.write!(cache, body <> String.duplicate(" ", size - byte_size(body)))
        assert window() == window
      end

      for bad <- ["not json", "[]", JSON.encode!(%{"openai" => %{"models" => %{"m" => 1}}})] do
        new_node(dir)
        File.write!(cache, bad)
        assert window() == nil
      end
    end
  end

  describe "refresh" do
    test "with no network the lookup uses the snapshot and does not wait on the refresh",
         %{tmp_dir: dir, cache: cache, marker: marker} do
      [{model, %{"limit" => %{"context" => context}}} | _] =
        Application.app_dir(:helyx_plugins, "priv/models_dev.json")
        |> File.read!()
        |> JSON.decode!()
        |> get_in(["openai", "models"])
        |> Enum.filter(&match?({_, %{"limit" => _}}, &1))

      serve(dir, fn conn ->
        receive do
          :go -> Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      # The lookup returns while the fetch waits for :go.
      assert info(model).context_window == context
      assert_receive {:fetch, task, _conn}
      assert File.exists?(marker)
      send(task, :go)
      await_end()

      assert info(model).context_window == context
      refute File.exists?(cache)
    end

    test "a 200 replaces the cache and the data, with its ETag; a 304 keeps the cache",
         %{tmp_dir: dir, cache: cache, marker: marker} do
      seed(cache, @good)
      serve(dir, &json(&1, 200, @newer, [{"etag", ~s("v2")}]))
      assert window() == 400_000
      {_task, conn} = await_refresh()
      # No compression is asked for, so the body cap counts decoded bytes.
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == []
      assert window() == 1_000
      assert %{"etag" => ~s("v2")} = JSON.decode!(File.read!(cache))

      # A new node loads the new cache file and sends its ETag.
      new_node(dir)
      File.rm!(marker)
      written = File.read!(cache)
      serve(dir, &Plug.Conn.send_resp(&1, 304, ""))
      assert window() == 1_000
      {_task, conn} = await_refresh()
      assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("v2")]
      assert File.read!(cache) == written
      assert window() == 1_000
    end

    test "an ETag that is not 1 to 256 bytes of printable ASCII is not kept",
         %{tmp_dir: dir, cache: cache, marker: marker} do
      for etag <- [<<?", 0xFF, ?">>, "\"é\"", String.duplicate("a", 257), ""] do
        new_node(dir)
        seed(cache, @good)
        _ = File.rm(marker)
        serve(dir, &json(&1, 200, @newer, [{"etag", etag}]))
        assert window() == 400_000
        await_refresh()
        assert window() == 1_000
        assert %{"etag" => nil} = JSON.decode!(File.read!(cache))
      end

      # The same rule at the read of the cache file: no If-None-Match.
      new_node(dir)
      File.rm!(marker)
      File.write!(cache, JSON.encode!(Map.put(@good, "etag", "a\nb")))
      serve(dir, &json(&1, 500, %{}))
      assert window() == 400_000
      {_task, conn} = await_refresh()
      assert Plug.Conn.get_req_header(conn, "if-none-match") == []
    end

    test "a failed refresh keeps the last good copy", %{
      tmp_dir: dir,
      cache: cache,
      marker: marker
    } do
      seed(cache, @good)
      written = File.read!(cache)

      for reply <- [
            &json(&1, 500, @newer),
            &Plug.Conn.send_resp(&1, 200, "not json"),
            &json(&1, 200, %{"openai" => %{"models" => %{@model => 1}}}),
            &Req.Test.transport_error(&1, :closed)
          ] do
        _ = File.rm(marker)
        serve(dir, reply)
        assert window() == 400_000
        await_refresh()
        assert window() == 400_000
        assert File.read!(cache) == written
      end
    end

    test "the body cap: 16 MB counted as the chunks arrive", %{
      tmp_dir: dir,
      cache: cache,
      marker: marker
    } do
      seed(cache, @good)
      body = JSON.encode!(@newer)

      for {size, window} <- [{@max_bytes, 1_000}, {@max_bytes + 1, 400_000}] do
        new_node(dir)
        seed(cache, @good)
        _ = File.rm(marker)
        padded = body <> String.duplicate(" ", size - byte_size(body))

        serve(dir, fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)

          for chunk <- chunks(padded), reduce: conn do
            conn -> elem(Plug.Conn.chunk(conn, chunk), 1)
          end
        end)

        assert window() == 400_000
        await_refresh()
        assert window() == window
      end
    end

    test "the whole fetch has a deadline; the Task is killed and the last good copy stays",
         %{tmp_dir: dir, cache: cache} do
      seed(cache, @good)

      serve(
        dir,
        fn conn ->
          Process.sleep(:infinity)
          conn
        end,
        # The fetch must reach the plug before the deadline. With no load it
        # takes about 20 ms for the first fetch of the VM and 1 ms after it.
        # @load_ms gives the margin for load (#709).
        fetch_ms: @load_ms
      )

      assert window() == 400_000
      {task, _conn} = await_refresh()
      refute Process.alive?(task)
      assert window() == 400_000
    end

    test "one attempt for each 24 hours: the marker", %{
      tmp_dir: dir,
      cache: cache,
      marker: marker
    } do
      seed(cache, @good)
      serve(dir, &json(&1, 500, %{}))
      now = System.os_time(:second)

      # A minute inside the day: no fetch.
      File.touch!(marker, now - @day_s + 60)
      assert window() == 400_000
      refute_receive {:fetch, _, _}, @load_ms

      File.touch!(marker, now - @day_s - 1)
      assert window() == 400_000
      await_refresh()
      # The refresh failed, and the marker it touched holds the next one.
      assert window() == 400_000
      refute_receive {:fetch, _, _}, @load_ms
      await_end()

      # A marker over a day in the future (a clock set back) is stale too.
      File.touch!(marker, now + @day_s + 60)
      assert window() == 400_000
      await_refresh()
    end

    test "one refresh for each node: a second refresh process starts no fetch",
         %{tmp_dir: dir, cache: cache} do
      seed(cache, @good)
      serve(dir, &json(&1, 500, %{}))
      # The test holds the registered name, as a running refresh does.
      Process.register(self(), Catalog)
      assert window() == 400_000
      refute_receive {:fetch, _, _}, @load_ms
      Process.unregister(Catalog)
    end

    test "with no url there is no refresh", %{tmp_dir: dir, marker: marker} do
      env(dir, url: nil)
      assert window() == nil
      refute File.exists?(marker)
    end
  end

  defp chunks(<<chunk::binary-size(65_536), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(rest), do: [rest]
end
