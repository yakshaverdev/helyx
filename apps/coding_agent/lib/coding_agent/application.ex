defmodule CodingAgent.Application do
  @moduledoc false
  # The supervisor of `helyx serve` (`CodingAgent.Serve`). The stop of the
  # VM (`init:stop/0`, the OTP answer to SIGTERM) stops the application,
  # and with it the server, in order (docs/features/serve.md).
  use Application

  @impl true
  def start(_type, _args), do: Task.Supervisor.start_link(name: CodingAgent.Servers)
end
