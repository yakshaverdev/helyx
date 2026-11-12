defmodule CodingAgent.Application do
  @moduledoc false
  # The supervisor of `helyx serve` (`CodingAgent.Serve`). The stop of the
  # VM (`init:stop/0`, the OTP answer to SIGTERM) stops the application,
  # and with it the server, in order (docs/features/serve.md). The children
  # stop in reverse order, so the server stops before the recorder: the
  # events of its last attempts reach the file.
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Helyx.Telemetry.Recorder, []}, {Task.Supervisor, name: CodingAgent.Servers}],
      strategy: :one_for_one,
      name: CodingAgent.Supervisor
    )
  end
end
