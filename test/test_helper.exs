# One `assert_receive` timeout for every test: the 100 ms default fails on a
# loaded machine. A wait that must not happen keeps its own stated margin.
ExUnit.start(assert_receive_timeout: 1_000)
