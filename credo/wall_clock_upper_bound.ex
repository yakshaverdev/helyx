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

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    ast = SourceFile.ast(source_file)
    time_fns = time_fns(ast)
    {_ast, ctx} = Macro.prewalk(ast, ctx, &walk(&1, &2, time_fns))
    ctx.issues
  end

  # Each test or function is one scope for the variables; a scope is not
  # walked again below its node.
  defp walk({scope, _, [_ | _]} = ast, ctx, time_fns) when scope in @scopes do
    taint = {tainted(ast, time_fns), time_fns}

    {_ast, ctx} =
      Macro.prewalk(ast, ctx, fn
        {op, _, [expr | _]} = node, ctx when op in [:assert, :refute] ->
          {node, Enum.reduce(bounds(op, expr), ctx, &check(&1, &2, taint))}

        {:assert_in_delta, meta, [value, expected, delta | _]} = node, ctx ->
          {node, check({:assert_in_delta, meta, [value, expected], delta}, ctx, taint)}

        node, ctx ->
          {node, ctx}
      end)

    {:ok, ctx}
  end

  defp walk(ast, ctx, _time_fns), do: {ast, ctx}

  # The names of the local functions whose body holds a time value.
  defp time_fns(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_head, body]} = node, acc when kind in [:def, :defp] ->
          {node, [{Credo.Code.Module.def_name(node), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    fixpoint(MapSet.new(), fn fns ->
      for {name, body} <- defs, time?(body, {MapSet.new(), fns}), into: fns, do: name
    end)
  end

  # The names of the variables in the scope that hold a time value.
  defp tainted(ast, time_fns) do
    {_ast, binds} =
      Macro.prewalk(ast, [], fn
        # Only the elapsed time of `:timer.tc` is a time value.
        {op, _, [{elapsed, _result}, {{:., _, [:timer, :tc]}, _, _} = expr]} = node, acc
        when op in [:=, :<-] ->
          {node, [{elapsed, expr} | acc]}

        {op, _, [pattern, expr]} = node, acc when op in [:=, :<-] ->
          {node, [{pattern, expr} | acc]}

        node, acc ->
          {node, acc}
      end)

    fixpoint(MapSet.new(), fn vars ->
      for {pattern, expr} <- binds,
          time?(expr, {vars, time_fns}),
          var <- vars_in(pattern),
          into: vars,
          do: var
    end)
  end

  defp fixpoint(set, step) do
    case step.(set) do
      ^set -> set
      bigger -> fixpoint(bigger, step)
    end
  end

  defp vars_in(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn
        {:@, _, _}, acc -> {:ok, acc}
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) -> {node, [name | acc]}
        node, acc -> {node, acc}
      end)

    vars
  end

  # The comparisons in an assertion that bound a value from above, as
  # {operator, meta, the value, the bound}. A `not` turns the assertion
  # around.
  defp bounds(op, {neg, _, [expr]}) when neg in [:not, :!], do: bounds(turn(op), expr)

  defp bounds(op, {cmp, meta, [left, right]})
       when cmp in [:<, :<=, :>, :>=, :in, :==, :===, :!=, :!==] do
    bound(op, cmp, meta, left, right) ++ bounds(op, left) ++ bounds(op, right)
  end

  defp bounds(op, {{:., _, [{:__aliases__, _, [:Kernel]}, cmp]}, meta, [left, right]})
       when cmp in [:<, :<=, :>, :>=] do
    bounds(op, {cmp, meta, [left, right]})
  end

  defp bounds(op, {call, _, args}) when is_list(args), do: bounds(op, [call | args])
  defp bounds(op, {left, right}), do: bounds(op, [left, right])
  defp bounds(op, list) when is_list(list), do: Enum.flat_map(list, &bounds(op, &1))
  defp bounds(_op, _leaf), do: []

  defp turn(:assert), do: :refute
  defp turn(:refute), do: :assert

  defp bound(:assert, cmp, meta, left, right) when cmp in [:<, :<=],
    do: [{cmp, meta, left, right}]

  defp bound(:assert, cmp, meta, left, right) when cmp in [:>, :>=],
    do: [{cmp, meta, right, left}]

  defp bound(:assert, :in, meta, left, {:.., _, [_, hi]}), do: [{:in, meta, left, hi}]
  defp bound(:assert, :in, meta, left, {:..//, _, [_, hi, _]}), do: [{:in, meta, left, hi}]

  defp bound(:refute, cmp, meta, left, right) when cmp in [:>, :>=],
    do: [{cmp, meta, left, right}]

  defp bound(:refute, cmp, meta, left, right) when cmp in [:<, :<=],
    do: [{cmp, meta, right, left}]

  # An equality bounds both sides. Only a side that is a time value itself
  # counts, not a result that a time value flows into.
  defp bound(:assert, cmp, meta, left, right) when cmp in [:==, :===],
    do: [{:equal, cmp, meta, [left, right]}]

  defp bound(:refute, cmp, meta, left, right) when cmp in [:!=, :!==],
    do: [{:equal, cmp, meta, [left, right]}]

  defp bound(_op, _cmp, _meta, _left, _right), do: []

  defp check({:equal, cmp, meta, sides}, ctx, taint) do
    if Enum.any?(sides, &time_itself?(&1, taint)) and not load_margin?(sides) do
      issue(ctx, cmp, meta)
    else
      ctx
    end
  end

  defp check({cmp, meta, value, limit}, ctx, taint) do
    if time?(value, taint) and not load_margin?(limit) do
      issue(ctx, cmp, meta)
    else
      ctx
    end
  end

  defp issue(ctx, cmp, meta) do
    put_issue(
      ctx,
      format_issue(ctx,
        message:
          "An upper bound of elapsed time fails under load. Assert order, " <>
            "or add a margin from a module attribute named `@load_...`.",
        trigger: to_string(cmp),
        line_no: meta[:line]
      )
    )
  end

  # A time variable, a time call, a local time function, or a sum or a
  # difference of one.
  defp time_itself?({op, _, [left, right]}, taint) when op in [:+, :-],
    do: time_itself?(left, taint) or time_itself?(right, taint)

  defp time_itself?({name, _, ctx}, {vars, _fns}) when is_atom(ctx),
    do: MapSet.member?(vars, name)

  defp time_itself?({{:., _, [mod, fun]}, _, _}, _taint), do: time_call?(mod, fun)

  defp time_itself?({name, _, args}, {_vars, fns}) when is_list(args),
    do: MapSet.member?(fns, name)

  defp time_itself?(_ast, _taint), do: false

  defp time?(ast, {vars, fns}) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        _node, true -> {:ok, true}
        {:@, _, _}, false -> {:ok, false}
        {{:., _, [mod, fun]}, _, _} = node, false -> {node, time_call?(mod, fun)}
        {name, _, ctx} = node, false when is_atom(ctx) -> {node, MapSet.member?(vars, name)}
        {name, _, args} = node, false when is_list(args) -> {node, MapSet.member?(fns, name)}
        node, false -> {node, false}
      end)

    found
  end

  defp time_call?({:__aliases__, _, mod}, fun), do: {mod, fun} in @time_calls
  defp time_call?(mod, fun), do: {mod, fun} in @time_calls

  defp load_margin?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:@, _, [{name, _, _}]} = node, acc when is_atom(name) ->
          {node, acc or String.starts_with?(Atom.to_string(name), "load_")}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
