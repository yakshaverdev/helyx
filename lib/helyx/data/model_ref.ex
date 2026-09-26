defmodule Helyx.ModelRef do
  @moduledoc """
  The string that names a model for a session, in the form `provider/model`.

  The prefix selects the provider plugin. The rest is passed to the provider
  unchanged. A session parses it once per start, resume, and switch;
  everything after that works with the struct.

  A ref is user input: the `--model` option, the `/model` command, a saved
  session file. It is valid UTF-8 of at most 256 bytes, with no whitespace
  and no control, format, or unassigned characters (Unicode category C), so
  a printed ref cannot carry a terminal control sequence. Characters that
  show as nothing, a Hangul filler for example, are accepted: two refs that
  look the same can differ.
  """

  @max_bytes 256

  @enforce_keys [:provider, :model]
  defstruct [:provider, :model]

  @type t :: %__MODULE__{provider: String.t(), model: String.t()}

  @doc """
  True when the string is within the bounds in the module doc, with or
  without the `provider/model` form. Such a string is safe to print.
  """
  @spec bounded?(String.t()) :: boolean()
  def bounded?(string) when is_binary(string) do
    byte_size(string) <= @max_bytes and String.valid?(string) and
      not String.match?(string, ~r/[\s\p{C}]/u)
  end

  @doc """
  Splits `provider/model` at the first slash. Both parts must be present, and
  the string must be within the bounds in the module doc.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_model_ref, String.t()}}
  def parse(string) when is_binary(string) do
    with true <- bounded?(string),
         [provider, model] when provider != "" and model != "" <-
           String.split(string, "/", parts: 2) do
      {:ok, %__MODULE__{provider: provider, model: model}}
    else
      _ -> {:error, {:invalid_model_ref, string}}
    end
  end

  @doc "Joins the struct back into the `provider/model` form."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{provider: provider, model: model}), do: provider <> "/" <> model
end
