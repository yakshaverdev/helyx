# `:slow` tests wait real seconds: `HELYX_SLOW=1` includes them, as
# `/ship` and the merge gate do (#295).
# One cap for every wait that must happen, `assert_receive` and the support
# helpers alike (`Helyx.Test.Events.wait_ms/0`). Only a failing test waits
# this long, so it is far above any delay that load makes: the precommit
# runs every project with Dialyzer and Credo at once (#295). A wait that
# must not happen keeps its own stated margin.
# The Credo check tests need the services of Credo. A start in a module's
# setup_all ends with that module, while other modules still run.
{:ok, _} = Application.ensure_all_started(:credo)

ExUnit.start(
  exclude: if(System.get_env("HELYX_SLOW") == "1", do: [], else: [:slow]),
  assert_receive_timeout: 30_000
)
