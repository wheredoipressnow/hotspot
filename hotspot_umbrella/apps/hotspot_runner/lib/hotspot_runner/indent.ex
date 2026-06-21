defmodule HotspotRunner.Indent do
  @moduledoc """
  Indentation ("whitespace") complexity of a source blob: a language-agnostic
  complexity proxy. Deeply and consistently indented code tends to be more
  complex, without needing a per-language parser.

  `metrics/1` returns `%{loc, indent_total, indent_max}` over non-blank lines, or
  `nil` for binary content (a NUL byte anywhere). `loc` counts non-blank lines;
  `indent_total` sums their leading-whitespace columns; `indent_max` is the
  deepest. Tabs expand to the next multiple of `@tab_width`.
  """

  @tab_width 4

  @type t :: %{loc: non_neg_integer, indent_total: non_neg_integer, indent_max: non_neg_integer}

  @spec metrics(binary) :: t | nil
  def metrics(content) when is_binary(content) do
    if binary?(content) do
      nil
    else
      content
      |> String.split("\n")
      |> Enum.reduce(%{loc: 0, indent_total: 0, indent_max: 0}, &accumulate/2)
    end
  end

  defp accumulate(line, acc) do
    if blank?(line) do
      acc
    else
      col = indent_columns(line, 0)

      %{
        loc: acc.loc + 1,
        indent_total: acc.indent_total + col,
        indent_max: max(acc.indent_max, col)
      }
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  # Leading-whitespace width in columns, tabs aligned to the next tab stop.
  defp indent_columns(<<?\s, rest::binary>>, col), do: indent_columns(rest, col + 1)

  defp indent_columns(<<?\t, rest::binary>>, col),
    do: indent_columns(rest, col + (@tab_width - rem(col, @tab_width)))

  defp indent_columns(_line, col), do: col

  defp binary?(content), do: :binary.match(content, <<0>>) != :nomatch
end
