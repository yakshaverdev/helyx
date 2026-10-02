# One cap for every wait that must happen, `assert_receive` and the support
# helpers alike (`Helyx.Test.Events.wait_ms/0`). Only a failing test waits
# this long, so it is far above any delay that load makes: the precommit
# runs every project with Dialyzer and Credo at once (#295). A wait that
# must not happen keeps its own stated margin.
ExUnit.start(assert_receive_timeout: 30_000)
