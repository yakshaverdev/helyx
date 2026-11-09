# One cap for every wait that must happen, `assert_receive` and the support
# helpers alike (`Helyx.Test.Events.wait_ms/0`). Only a failing test waits
# this long, so it is far above any delay that load makes: the precommit
# runs every project with Dialyzer and Credo at once (#295). A wait that
# must not happen keeps its own stated margin.
# `:slow` tests wait real seconds: `HELYX_SLOW=1` includes them, as
# the merge gate of `/orchestrate` does (#295).
# No test reads the user's MCP config or starts a server that it names
# (`Helyx.Tool.MCP`): the file is in a folder that does not exist.
Application.put_env(
  :helyx_plugins,
  :mcp_config,
  Path.expand("../_build/test_no_mcp/mcp.json", __DIR__)
)

ExUnit.start(
  exclude: if(System.get_env("HELYX_SLOW") == "1", do: [], else: [:slow]),
  assert_receive_timeout: 30_000
)
