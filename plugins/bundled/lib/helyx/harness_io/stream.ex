defmodule Helyx.HarnessIO.Stream do
  @moduledoc false
  # The program stream that the harness providers share (ADR 0005). Each
  # provider state embeds it as `stream`, so `Helyx.HarnessIO` reads and
  # writes one shape. A `terminal` means the provider process must stop with
  # that error, and output is no longer read.
  @derive {Inspect, except: [:env]}
  defstruct port: nil, buffer: [], size: 0, terminal: nil, closing: nil, handles: [], env: []
end
