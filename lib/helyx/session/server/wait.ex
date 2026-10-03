defmodule Helyx.Session.Server.Wait do
  @moduledoc false
  # The wait before the next turn (docs/features/long-lived-harness.md,
  # "Turn cleanup"): the answer of the hands to `Hands.request_cancel/2`
  # (`hands`), the answer to an interrupt or an idle close (`reply`), and
  # the release of a provider process that ends (`provider`, until the
  # hands' `:provider_down`). Each part is bounded: the hands by their
  # release deadlines, a reply by its armed kill. `callers` are the abort
  # callers, who get their reply at the end. Every message of a client
  # queues until the end.
  defstruct [:hands, :reply, :provider, callers: []]
end
