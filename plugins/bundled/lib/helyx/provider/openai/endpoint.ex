defmodule Helyx.Provider.OpenAI.Endpoint do
  @moduledoc false
  # The constants of one endpoint of `Helyx.Provider.OpenAI`, checked when
  # the endpoint module compiles. The options and their bounds:
  # `docs/features/openai-compatible.md`.

  @enforce_keys [:id, :base_url]
  defstruct [:id, :base_url, key_env: nil, headers: [], catalog: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          base_url: String.t(),
          key_env: String.t() | nil,
          headers: [{String.t(), String.t() | :session_id}],
          catalog: String.t() | nil
        }

  @max_headers 16
  @max_name_bytes 256
  @max_value_bytes 4_096
  # The engine sets these; an endpoint cannot replace them.
  @reserved ~w(authorization user-agent)

  @doc false
  # The endpoint of the `use` options; a bad option raises with its name,
  # so the compile of the endpoint module fails.
  @spec new!(keyword()) :: t()
  def new!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Helyx.Provider.OpenAI options must be a keyword list")

    endpoint = struct!(__MODULE__, opts)

    for {key, value} <- Map.from_struct(endpoint), not valid?(key, value) do
      raise ArgumentError, "bad Helyx.Provider.OpenAI option #{key}: #{inspect(value)}"
    end

    endpoint
  end

  defp valid?(:id, id) do
    is_binary(id) and not String.contains?(id, "/") and
      match?({:ok, _}, Helyx.ModelRef.parse(id <> "/m"))
  end

  defp valid?(:base_url, url), do: http?(url)
  defp valid?(:key_env, nil), do: true

  defp valid?(:key_env, name),
    do: is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]{0,255}\z/

  defp valid?(:catalog, id), do: id in [nil | Helyx.ModelInfo.Catalog.ids()]

  defp valid?(:headers, headers),
    do: is_list(headers) and length(headers) <= @max_headers and Enum.all?(headers, &header?/1)

  defp header?({name, value}) when is_binary(name) do
    byte_size(name) in 1..@max_name_bytes and name =~ ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/ and
      String.downcase(name) not in @reserved and value?(value)
  end

  defp header?(_header), do: false

  defp value?(:session_id), do: true

  defp value?(value) when is_binary(value),
    do: byte_size(value) <= @max_value_bytes and value =~ ~r/\A[\x20-\x7e\t]*\z/

  defp value?(_value), do: false

  # A valid UTF-8 string first: `URI.new/1` raises on other binaries. The
  # engine appends the path, so a query or a fragment would end before it.
  defp http?(url) do
    is_binary(url) and String.valid?(url) and
      match?(
        {:ok, %URI{scheme: scheme, host: <<_, _::binary>>, query: nil, fragment: nil}}
        when scheme in ["http", "https"],
        URI.new(url)
      )
  end
end
