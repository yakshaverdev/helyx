defmodule Helyx.ModelInfo.Catalog do
  @moduledoc false
  # Step 3 of the source rule: the window and the prices of a model from the
  # models.dev catalog. `docs/features/usage-and-limits.md`, "The catalog",
  # "Bounds", and "Ownership". Not a plugin (ADR 0005).
  #
  # The data is the output of `slim/1` and lives in `:persistent_term`: the
  # first lookup of a node loads the cache file, else the bundled snapshot.
  # On disk it has the shape of `api.json` (`json/1`). A lookup starts a
  # refresh at most once a day for each cache directory; no lookup waits on
  # it, and a failed refresh keeps the last good copy.
  #
  # Application env of `helyx_plugins`, key `:model_catalog`: `dir`, `url`
  # (nil turns the refresh off), `req_options`, and `fetch_ms` (the
  # whole-fetch deadline).
  # Each lookup checks it, so a bad value fails the provider start with its
  # key, as a bad `:models` entry does.

  import Helyx.Usage, only: [wire_window?: 1]

  @catalog_ids %{
    "claude-code" => "anthropic",
    "codex" => "openai",
    "opencode-go" => "opencode-go",
    "opencode" => "opencode"
  }
  @defaults %{
    dir: "~/.helyx/cache",
    url: "https://models.dev/api.json",
    req_options: [],
    fetch_ms: 60_000
  }
  @max_bytes 16 * 1024 * 1024
  @chunk_ms 30_000
  @day_s 86_400
  # A fetch longer than the day would overlap the next attempt.
  @max_fetch_ms @day_s * 1000
  # The bound of a model ref (`Helyx.ModelRef`).
  @max_id_bytes 256
  @max_etag_bytes 256
  @price_keys %{
    "input" => :input,
    "output" => :output,
    "cache_read" => :cache_read,
    "cache_write" => :cache_write
  }

  @doc false
  # The window and the price set of the catalog entry of the model, each
  # nil when the catalog has none. A provider with no catalog id has none.
  @spec lookup(String.t(), String.t()) ::
          {:ok, Helyx.ModelInfo.t()} | {:error, {:bad_config, [term()]}}
  def lookup(provider_id, model) do
    with {:ok, config} <- config() do
      {:ok, entry(@catalog_ids[provider_id], model, config)}
    end
  end

  defp entry(nil, _model, _config), do: %Helyx.ModelInfo{}

  defp entry(id, model, config) do
    data = load(config.dir).data
    refresh(config)
    get_in(data, [id, model]) || %Helyx.ModelInfo{}
  end

  # Config is a boundary: a keyword list of the known keys, else the path
  # of the first bad key, `[:model_catalog, key]`.
  defp config do
    env = Application.get_env(:helyx_plugins, :model_catalog, [])

    with {:ok, keys} <- Helyx.ModelInfo.check(env, [:model_catalog], &config_key/2) do
      config = Map.merge(@defaults, Map.new(keys))
      {:ok, %{config | dir: Path.expand(config.dir)}}
    end
  end

  defp config_key(:dir, dir) when is_binary(dir) and dir != "", do: {:ok, dir}
  defp config_key(:url, nil), do: {:ok, nil}
  defp config_key(:url, url) when is_binary(url), do: if(http?(url), do: {:ok, url}, else: :error)
  defp config_key(:fetch_ms, ms) when ms in 1..@max_fetch_ms//1, do: {:ok, ms}

  defp config_key(:req_options, options),
    do: if(Keyword.keyword?(options), do: {:ok, options}, else: :error)

  defp config_key(_key, _value), do: :error

  # A valid UTF-8 string first: `URI.new/1` raises on other binaries.
  defp http?(url) do
    String.valid?(url) and
      match?(
        {:ok, %URI{scheme: scheme, host: <<_, _::binary>>}} when scheme in ["http", "https"],
        URI.new(url)
      )
  end

  # Slim

  @doc false
  # The four catalog ids of a models.dev `api.json`, each model with only
  # its window and its price set, each checked alone. An entry whose id is
  # not 1 to 256 bytes is dropped. A window outside the wire bound is
  # dropped (0 is unknown). A price set that fails the check of a config
  # price set (`ModelInfo.check_prices/1`) is dropped; the keys that Helyx
  # has no price for are left out first, and a tier that is not of type
  # `context` fails the check. A catalog id with no entry left is dropped,
  # so `%{}` means no catalog. The snapshot, the cache file, and each
  # refresh pass it.
  @spec slim(term()) :: %{String.t() => %{String.t() => Helyx.ModelInfo.t()}}
  def slim(api) when is_map(api) do
    for {_provider, id} <- @catalog_ids,
        %{"models" => models} when is_map(models) <- [api[id]],
        models = models(models),
        models != %{},
        into: %{},
        do: {id, models}
  end

  def slim(_api), do: %{}

  defp models(models) do
    for {model, entry} <- models,
        id?(model),
        entry = entry(entry),
        entry != %Helyx.ModelInfo{},
        into: %{} do
      {model, entry}
    end
  end

  defp id?(id), do: is_binary(id) and byte_size(id) in 1..@max_id_bytes

  defp entry(entry) when is_map(entry),
    do: %Helyx.ModelInfo{context_window: window(entry["limit"]), prices: prices(entry["cost"])}

  defp entry(_entry), do: %Helyx.ModelInfo{}

  defp window(%{"context" => context}) when wire_window?(context), do: context
  defp window(_limit), do: nil

  defp prices(cost) do
    case Helyx.ModelInfo.check_prices(keywords(cost)) do
      {:ok, prices} -> prices
      {:error, _reason} -> nil
    end
  end

  # A price set of `api.json` as a config price set.
  defp keywords(cost) when is_map(cost) do
    prices = for {key, price} <- cost, atom = @price_keys[key], do: {atom, price}
    if Map.has_key?(cost, "tiers"), do: prices ++ [tiers: tiers(cost["tiers"])], else: prices
  end

  defp keywords(cost), do: cost

  defp tiers(tiers) when is_list(tiers), do: Enum.map(tiers, &tier/1)
  defp tiers(tiers), do: tiers

  defp tier(%{"tier" => %{"type" => "context", "size" => size}} = tier),
    do: {size, keywords(tier)}

  defp tier(_tier), do: :not_a_context_tier

  @doc false
  # The data of `slim/1` in the shape of `api.json`, as the snapshot and
  # the cache file hold it. `slim(json(data)) == data`.
  @spec json(map()) :: map()
  def json(data) do
    Map.new(data, fn {id, models} ->
      {id, %{"models" => Map.new(models, fn {model, entry} -> {model, json_entry(entry)} end)}}
    end)
  end

  defp json_entry(entry) do
    %{"limit" => entry.context_window && %{"context" => entry.context_window}}
    |> Map.put("cost", entry.prices && json_prices(entry.prices))
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  defp json_prices(prices) do
    {tiers, set} = Map.pop(prices, :tiers)
    json = Map.new(set, fn {key, price} -> {Atom.to_string(key), price} end)

    if tiers,
      do: Map.put(json, "tiers", Enum.map(tiers, &json_tier/1)),
      else: json
  end

  defp json_tier({size, set}),
    do: Map.put(json_prices(set), "tier", %{"type" => "context", "size" => size})

  # Load

  # The first load of a node reads and puts under a lock of the directory,
  # and puts only when the entry is still unset. A refresh loads before its
  # fetch, so its put comes after every first load, and no load that read
  # the old cache file can put it over the data of the refresh. The lock id
  # is the resource and the requester (`:global.trans/3`).
  defp load(dir) do
    :persistent_term.get({__MODULE__, dir}, nil) ||
      :global.trans(
        {{__MODULE__, dir}, self()},
        fn ->
          :persistent_term.get({__MODULE__, dir}, nil) ||
            put(dir, read(cache(dir)) || %{etag: nil, data: snapshot()})
        end,
        [node()]
      )
  end

  defp put(dir, loaded) do
    :persistent_term.put({__MODULE__, dir}, loaded)
    loaded
  end

  # The cache file, at most 16 MB, with its ETag; nil when it is missing,
  # too large, or has no good entry.
  defp read(path) do
    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_bytes <-
           File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
         {:ok, json} <- JSON.decode(bytes),
         data when data != %{} <- slim(json) do
      %{etag: etag(json["etag"]), data: data}
    else
      _bad -> nil
    end
  end

  defp snapshot,
    do:
      :helyx_plugins
      |> Application.app_dir("priv/models_dev.json")
      |> File.read!()
      |> JSON.decode!()
      |> slim()

  defp cache(dir), do: Path.join(dir, "models.dev.json")
  defp marker(dir), do: Path.join(dir, "models.dev.attempt")

  # Refresh

  defp refresh(%{url: nil}), do: :ok

  defp refresh(config) do
    if stale?(config.dir), do: spawn(fn -> register() && run(config) end)
    :ok
  end

  defp stale?(dir) do
    case File.stat(marker(dir), time: :posix) do
      # A marker a day in the future (a clock set back) is also stale.
      {:ok, %{mtime: mtime}} -> abs(System.os_time(:second) - mtime) > @day_s
      {:error, _reason} -> true
    end
  end

  # The registered name keeps one refresh for each node.
  defp register do
    Process.register(self(), __MODULE__)
  rescue
    ArgumentError -> false
  end

  # The marker is touched before the fetch, so a refresh that fails or
  # crashes also counts as the attempt of the day. A lookup that saw the old
  # marker before this refresh touched it starts no second fetch: the check
  # runs again under the name.
  defp run(config) do
    with true <- stale?(config.dir),
         :ok <- File.mkdir_p(config.dir),
         :ok <- File.touch(marker(config.dir)),
         %{etag: etag} = load(config.dir),
         {:ok, body, etag} <- fetch(config, etag),
         {:ok, json} <- JSON.decode(body),
         data when data != %{} <- slim(json) do
      write(config.dir, %{etag: etag, data: data})
    end
  end

  # The fetch runs in a linked Task under the whole-fetch deadline, so a
  # stalled server never keeps the refresh process past it.
  defp fetch(config, etag) do
    task = Task.async(fn -> get(config, etag) end)
    result = Task.yield(task, config.fetch_ms) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, %{status: 200, body: body} = resp}} when is_list(body) ->
        etag = resp |> Req.Response.get_header("etag") |> List.first() |> etag()
        {:ok, IO.iodata_to_binary(body), etag}

      _not_modified_or_failed ->
        :error
    end
  end

  # An ETag from the network or the disk: kept when it is 1 to 256 bytes
  # of printable ASCII, so the header and the cache file can hold it; else
  # nil, and the next fetch sends no `If-None-Match`.
  defp etag(etag) when is_binary(etag) and byte_size(etag) in 1..@max_etag_bytes do
    if etag =~ ~r/\A[\x20-\x7e]+\z/, do: etag
  end

  defp etag(_etag), do: nil

  defp get(config, etag) do
    headers = if etag, do: [{"if-none-match", etag}], else: []

    # The options of this module come last, so config cannot undo the caps.
    Req.get(
      config.url,
      config.req_options ++
        [headers: headers, receive_timeout: @chunk_ms, retry: false, into: &collect/2]
    )
  end

  # The body cap counts the bytes as the chunks arrive. Over the cap the
  # fetch stops, and a body that is not a list is no catalog.
  defp collect({:data, data}, {req, resp}) do
    resp = Req.Response.update_private(resp, :bytes, byte_size(data), &(&1 + byte_size(data)))

    if Req.Response.get_private(resp, :bytes) > @max_bytes,
      do: {:halt, {req, %{resp | body: :too_large}}},
      else: {:cont, {req, %{resp | body: [resp.body, data]}}}
  end

  # A temporary file, then the rename, so a reader finds the old or the new
  # cache file, never a part of one.
  defp write(dir, loaded) do
    tmp = "#{cache(dir)}.#{System.pid()}.#{System.unique_integer([:positive])}"
    json = JSON.encode!(Map.put(json(loaded.data), "etag", loaded.etag))

    # The encode can be longer than the body; the cache file keeps the cap.
    with true <- byte_size(json) <= @max_bytes,
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, cache(dir)) do
      put(dir, loaded)
    else
      _error -> File.rm(tmp)
    end
  end
end
