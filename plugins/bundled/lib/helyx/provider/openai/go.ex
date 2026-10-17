defmodule Helyx.Provider.OpenAI.Go do
  @moduledoc """
  The OpenCode Go endpoint of `Helyx.Provider.OpenAI`: `opencode-go/<model>`,
  with the key in `OPENCODE_API_KEY` and the session id in the
  `x-opencode-session` header.
  """
  use Helyx.Provider.OpenAI,
    id: "opencode-go",
    base_url: "https://opencode.ai/zen/go/v1",
    key_env: "OPENCODE_API_KEY",
    headers: [{"x-opencode-session", :session_id}],
    catalog: "opencode-go"
end
