defmodule Helyx.Credo.WallClockUpperBound do
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    explanations: [
      check: """
      A test asserts order and properties, not an upper bound of elapsed
      wall-clock time. Other worktrees and precommit runs load the machine,
      so an upper bound fails at random (#193, #221).

      This check reports an `assert` or `refute` that puts an upper bound on
      a time value. A time value is an expression that contains
      `System.monotonic_time`, `System.system_time`, `System.os_time`,
      `:erlang.monotonic_time`, `:erlang.system_time`, `:erlang.timestamp`,
      `:os.system_time`, `:os.timestamp`, `DateTime.utc_now`, or the elapsed
      time of `:timer.tc`, or a variable or a local function that gets its
      value from one, in the same function or test. The forms are `<`, `<=`,
      `>` and `>=` in either order, `==` and `===` with a side that is a time
      value itself (a time variable, a time call, or a sum or a difference
      of one), `refute` and `not` with the operator turned around (so a
      refuted `!=` or `!==` too), `in lo..hi`, `Kernel.<`, `Kernel.<=`,
      `Kernel.>`, `Kernel.>=`, and `assert_in_delta`. A comparison of two time values is reported
      too: the check cannot tell an instant from a deadline such as
      `start + 300`. For a true order of two instants, put
      `# credo:disable-for-next-line` above the assertion.

      A wait that must not happen is checked with a margin for load. State
      the margin in a module attribute whose name starts with `load_`, and
      use it in the bound:

          # Room for scheduler load: far above the delays that load makes,
          # far below the wait that must not happen.
          @load_ms 250

          assert System.monotonic_time(:millisecond) - start < @load_ms

      The check sees only the syntax of one file. It does not follow a time
      value through a `case` clause, a message, a process, a function of
      another module, a function parameter, or a pipe into the operator.
      It does not see a bound written as a named operator call, such as
      `Kernel.not/1`, `Kernel.in/2` or `:erlang.</2`. In an equality, it
      does not see a time value inside `*`, `/`, unary `-`, `div`, `rem`,
      `round`, `trunc`, a unit conversion or another function call, or a
      tuple or list literal, and a margin on the time side
      (`elapsed + @load_ms == 100`) passes.
      It can report too much: a variable name is a time value in its whole
      scope once one binding gives it one, and a value that any time value
      flows into is a time value. Only a direct `{elapsed, result}` match
      on `:timer.tc` keeps the result out.
      """
    ]

  @time_calls [
    {[:System], :monotonic_time},
    {[:System], :system_time},
    {[:System], :os_time},
    {:erlang, :monotonic_time},
    {:erlang, :system_time},
    {:erlang, :timestamp},
    {:os, :system_time},
    {:os, :timestamp},
    {[:DateTime], :utc_now},
    {:timer, :tc}
  ]

  @scopes [:test, :def, :defp, :setup, :setup_all]

  # A comparison and its negation, for an assertion under `refute` or `not`.
  @negate %{<: :>=, <=: :>, >: :<=, >=: :<, ==: :!=, ===: :!==, !=: :==, !==: :===}
  @comparisons [:in | Map.keys(@negate)]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    ast = SourceFile.ast(source_file)
    fns = time_fns(ast)

    # Each test or function is one scope for the variables; a scope is not
    # walked again below its node.
    found =
      for scope <- nodes(ast, &scope?/1),
          scope?(scope),
          taint = {tainted(scope, fns), fns},
          node <- nodes(scope),
          {trigger, meta, how, values, limit} <- bounds(node),
          Enum.any?(values, &time?(&1, how, taint)) and not load_margin?(limit),
          do: {trigger, meta}

    Enum.reduce(found, ctx, &issue/2).issues
  end

  defp scope?(node), do: match?({scope, _, [_ | _]} when scope in @scopes, node)

  # The nodes of `ast` in prewalk order. The walk does not go below a node
  # that `stop?` accepts.
  defp nodes(ast, stop? \\ fn _node -> false end) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        {if(stop?.(node), do: :ok, else: node), [node | acc]}
      end)

    Enum.reverse(acc)
  end

  # The nodes that can hold a value: a module attribute and all below it are
  # left out, since the `{name, _, nil}` in `@name` looks like a variable.
  defp value_nodes(ast) do
    attribute? = &match?({:@, _, _}, &1)
    ast |> nodes(attribute?) |> Enum.reject(attribute?)
  end

  # The names of the local functions whose body holds a time value.
  defp time_fns(ast) do
    defs =
      for {kind, _, [_head, body]} = node <- nodes(ast),
          kind in [:def, :defp],
          do: {Credo.Code.Module.def_name(node), body}

    fixpoint(fn fns ->
      for {name, body} <- defs, time?(body, :contains, {MapSet.new(), fns}), into: fns, do: name
    end)
  end

  # The names of the variables in the scope that hold a time value.
  defp tainted(scope, fns) do
    binds = for {op, _, [pattern, expr]} <- nodes(scope), op in [:=, :<-], do: bind(pattern, expr)

    fixpoint(fn vars ->
      for {pattern, expr} <- binds,
          time?(expr, :contains, {vars, fns}),
          {name, _, ctx} when is_atom(name) and is_atom(ctx) <- value_nodes(pattern),
          into: vars,
          do: name
    end)
  end

  # Only the elapsed time of `:timer.tc` is a time value.
  defp bind({elapsed, _result}, {{:., _, [:timer, :tc]}, _, _} = expr), do: {elapsed, expr}
  defp bind(pattern, expr), do: {pattern, expr}

  defp fixpoint(set \\ MapSet.new(), step) do
    case step.(set) do
      ^set -> set
      bigger -> fixpoint(bigger, step)
    end
  end

  # The upper bounds that an assertion puts on a value, as {trigger, meta,
  # how a time value is found, the values, the bound}.
  defp bounds({op, _, [expr | _]}) when op in [:assert, :refute], do: bounds(expr, op == :refute)

  defp bounds({:assert_in_delta, meta, [value, expected, delta | _]}),
    do: [{:assert_in_delta, meta, :contains, [value, expected], delta}]

  defp bounds(_node), do: []

  defp bounds({neg, _, [expr]}, negated) when neg in [:not, :!], do: bounds(expr, not negated)

  defp bounds({{:., _, [{:__aliases__, _, [:Kernel]}, cmp]}, meta, [left, right]}, negated)
       when cmp in [:<, :<=, :>, :>=],
       do: bounds({cmp, meta, [left, right]}, negated)

  defp bounds({cmp, meta, [left, right]}, negated) when cmp in @comparisons do
    # A negated `in` has no negation in the map, so it is no bound.
    asserted = if negated, do: @negate[cmp], else: cmp
    bound(asserted, cmp, meta, left, right) ++ bounds([left, right], negated)
  end

  defp bounds({call, _, args}, negated) when is_list(args), do: bounds([call | args], negated)
  defp bounds({left, right}, negated), do: bounds([left, right], negated)
  defp bounds(list, negated) when is_list(list), do: Enum.flat_map(list, &bounds(&1, negated))
  defp bounds(_leaf, _negated), do: []

  defp bound(op, cmp, meta, left, right) when op in [:<, :<=],
    do: [{cmp, meta, :contains, [left], right}]

  defp bound(op, cmp, meta, left, right) when op in [:>, :>=],
    do: [{cmp, meta, :contains, [right], left}]

  defp bound(:in, cmp, meta, left, {range, _, [_, hi | _]}) when range in [:.., :..//],
    do: [{cmp, meta, :contains, [left], hi}]

  # An equality bounds both sides. Only a side that is a time value itself
  # counts, not a result that a time value flows into.
  defp bound(op, cmp, meta, left, right) when op in [:==, :===],
    do: [{cmp, meta, :itself, [left, right], [left, right]}]

  defp bound(_op, _cmp, _meta, _left, _right), do: []

  defp issue({trigger, meta}, ctx) do
    put_issue(
      ctx,
      format_issue(ctx,
        message:
          "An upper bound of elapsed time fails under load. Assert order, " <>
            "or add a margin from a module attribute named `@load_...`.",
        trigger: to_string(trigger),
        line_no: meta[:line]
      )
    )
  end

  # `:contains`: the value holds a time value anywhere. `:itself`: the value
  # is a time value, or a sum or a difference of one.
  defp time?(ast, :contains, taint), do: Enum.any?(value_nodes(ast), &time_node?(&1, taint))

  defp time?({op, _, [left, right]}, :itself, taint) when op in [:+, :-],
    do: time?(left, :itself, taint) or time?(right, :itself, taint)

  defp time?(ast, :itself, taint), do: time_node?(ast, taint)

  defp time_node?({{:., _, [mod, fun]}, _, _}, _taint), do: time_call?(mod, fun)
  defp time_node?({name, _, ctx}, {vars, _fns}) when is_atom(ctx), do: name in vars
  defp time_node?({name, _, args}, {_vars, fns}) when is_list(args), do: name in fns
  defp time_node?(_ast, _taint), do: false

  defp time_call?({:__aliases__, _, mod}, fun), do: {mod, fun} in @time_calls
  defp time_call?(mod, fun), do: {mod, fun} in @time_calls

  defp load_margin?(ast) do
    Enum.any?(nodes(ast), fn
      {:@, _, [{name, _, _}]} when is_atom(name) ->
        String.starts_with?(Atom.to_string(name), "load_")

      _node ->
        false
    end)
  end
end
