defmodule Helyx.Provider.ClaudeCode.Interrupt do
  @moduledoc false
  # A pending interrupt of `Helyx.Provider.ClaudeCode`: its `from`, its
  # `request_id` once written, and whether its control response and the
  # turn's `result` came.
  @enforce_keys [:from]
  defstruct [:from, :request_id, response?: false, result?: false]
end
