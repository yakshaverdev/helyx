defmodule Helyx.Credo.JSONDecode do
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    explanations: [
      check: """
      A JSON decode in `lib/` code goes through `Helyx.JSON.decode/1` (#792).
      `JSON.decode/1` raises `SystemLimitError` for an integer over the
      largest integer of the BEAM, in place of an error result, and the
      reviews found the raise at five boundaries (#782, #786).

      This check reports a call or a capture of `JSON.decode` or
      `JSON.decode!`, of any arity, in a file in a `lib/` folder, except in
      the module `Helyx.JSON`. Tests are not checked. A decode whose
      decoders cannot raise, such as one with an integer decoder that
      bounds the digits, has `# credo:disable-for-next-line` with its
      reason.

      The check sees only the syntax of one file. It does not see a call
      after `import JSON`, after an alias of `JSON` to another name,
      through `apply/3` or a variable, written `Elixir.JSON.decode`, or of
      the OTP module `:json`, which raises on the same integer. It reports
      `JSON.decode` after `alias Helyx.JSON`: write the full name.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{filename: path} = source_file, params) do
    if path =~ ~r"(^|/)lib/" do
      ctx = Context.build(source_file, params, __MODULE__)
      {_ast, ctx} = Macro.prewalk(SourceFile.ast(source_file), ctx, &walk/2)
      ctx.issues
    else
      []
    end
  end

  # The walk does not go into `Helyx.JSON`.
  defp walk({:defmodule, _, [{:__aliases__, _, [:Helyx, :JSON]} | _]}, ctx), do: {:ok, ctx}

  defp walk({{:., _, [{:__aliases__, _, [:JSON]}, fun]}, meta, _args} = node, ctx)
       when fun in [:decode, :decode!],
       do: {node, issue(ctx, "JSON.#{fun}", meta[:line])}

  defp walk(node, ctx), do: {node, ctx}

  defp issue(ctx, trigger, line) do
    put_issue(
      ctx,
      format_issue(ctx,
        message:
          "Decode JSON with `Helyx.JSON.decode/1`: `#{trigger}` raises " <>
            "`SystemLimitError` for an integer over the largest integer of the BEAM.",
        trigger: trigger,
        line_no: line
      )
    )
  end
end
