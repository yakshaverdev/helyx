defmodule Helyx.HarnessIO.Stream do
  @moduledoc false
  # The program stream that the harness providers share (ADR 0005):
  # `port` the program's port, `buffer` (iodata) and `size` the part of a
  # line that has no newline yet, `terminal` the error that stops the
  # provider process, `closing` the `from` of a close, `handles` the held
  # handles of the provider's programs, and `env` the option `env` as name
  # and value pairs (`Helyx.HarnessIO.env/1`). Each provider state embeds
  # it as `stream`, so `Helyx.HarnessIO` reads and writes one shape.
  @derive {Inspect, except: [:env]}
  defstruct port: nil, buffer: [], size: 0, terminal: nil, closing: nil, handles: [], env: []
end
