defmodule Helyx.Context do
  @moduledoc """
  What a provider sees on one call: a system prompt, the messages, and the
  tools the hands can run. `system` and `tools` are what a model provider
  sends on this call. A harness provider may use only `messages`
  (`Helyx.Provider`).
  """

  defstruct system: nil, messages: [], tools: []

  @type t :: %__MODULE__{
          system: String.t() | nil,
          messages: [Helyx.Message.t()],
          tools: [Helyx.Tool.spec()]
        }
end
