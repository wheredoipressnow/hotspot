defmodule HotspotRunner.Blame do
  @moduledoc """
  Parses `git blame --line-porcelain` (see `HotspotRunner.Git.blame_args/2`) into
  one entry per current line, in file order:

      %{line: 1, sha: "ab12…", author: "Ada", time: 1_700_000_000,
        summary: "Add parser", code: "defmodule …"}

  ## Framing (porcelain)

  Each line is a group:

    * a header `"<40-hex-sha> <orig_lineno> <final_lineno> [group_size]"`;
    * repeated key/value lines; we keep `author`, `author-time`, `summary`
      (`--line-porcelain` repeats these on every line, so each line is
      self-describing);
    * the content line, prefixed with a TAB; stripping the tab yields the code
      and closes the group.

  `summary` is the commit subject, the "change reason" for that line.
  """

  @header ~r/^[0-9a-f]{40} \d+ \d+(?: \d+)?$/

  @type line :: %{
          line: pos_integer,
          sha: String.t(),
          author: String.t(),
          time: integer,
          summary: String.t(),
          code: String.t()
        }

  @doc "Parse a full `--line-porcelain` buffer into ordered line entries."
  @spec parse(binary) :: [line]
  def parse(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, []}, &reduce_line/2)
    |> elem(1)
    |> Enum.reverse()
  end

  # Content line (TAB-prefixed) closes the current group into a finished entry.
  defp reduce_line("\t" <> code, {cur, done}) when is_map(cur) do
    {nil, [Map.put(cur, :code, code) | done]}
  end

  defp reduce_line(line, {cur, done}) do
    cond do
      Regex.match?(@header, line) ->
        [sha, _orig, final | _] = String.split(line, " ")
        {%{sha: sha, line: String.to_integer(final), author: "", time: 0, summary: ""}, done}

      cur == nil ->
        {nil, done}

      true ->
        {apply_field(cur, line), done}
    end
  end

  defp apply_field(cur, "author " <> name), do: %{cur | author: name}
  defp apply_field(cur, "author-time " <> t), do: %{cur | time: to_int(t)}
  defp apply_field(cur, "summary " <> s), do: %{cur | summary: s}
  defp apply_field(cur, _other), do: cur

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
