defmodule HotspotRunner.ParseError do
  @moduledoc "Raised when the git byte stream does not match the expected framing."
  defexception [:message]
end

defmodule HotspotRunner.Parser do
  @moduledoc """
  Streaming parser for the byte stream produced by:

      git log <ref> -z --numstat -M --pretty=format:'%x00%H%x00%at%x00%aN%x00%aE%x00%P'

  Framing (derived from captured real git output):

    * Each commit begins with a leading NUL then a 40- or 64-hex SHA.
    * Header: `SHA \\0 epoch \\0 name \\0 email \\0 parents`, terminated by `\\n`.
    * The numstat block follows the `\\n`; each entry is NUL-terminated:
      * normal/binary: `"added\\tdeleted\\tpath"` (binary => added/deleted are `-`)
      * rename: `"added\\tdeleted\\t" \\0 oldpath \\0 newpath`
    * Merge / empty commits have a header but no numstat entries.

  Bytes are kept as bytes until a complete commit slice is isolated, so multibyte
  paths can never be split across a decode boundary, and the whole git output is
  never held in memory (only the still-open trailing commit is retained).

  A commit record is a map:

      %{sha, committed_at, author_name, author_email, parent_count, files, renames}

  where `files` is a list of `%{path, added, deleted}` (added/deleted `nil` for
  binary) and `renames` a list of `%{old_path, new_path, similarity}`.
  """

  alias HotspotRunner.ParseError

  defstruct buf: <<>>

  @type t :: %__MODULE__{buf: binary()}

  @doc "A fresh streaming-parser state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append a chunk; returns `{state, completed_commits}`. Emits every commit that
  is now fully closed (i.e. all but the still-open trailing commit).
  """
  @spec push(t(), binary()) :: {t(), [map()]}
  def push(%__MODULE__{buf: buf0} = state, chunk) do
    buf = buf0 <> chunk
    starts = commit_starts(buf)

    case starts do
      [] ->
        {%{state | buf: buf}, []}

      [_only] ->
        {%{state | buf: buf}, []}

      _ ->
        commits =
          starts
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [from, to] ->
            parse_commit_text(binary_part(buf, from + 1, to - from - 1))
          end)

        last = List.last(starts)
        rest = binary_part(buf, last, byte_size(buf) - last)
        {%{state | buf: rest}, commits}
    end
  end

  @doc "Flush the final open commit at end of stream."
  @spec finish(t()) :: [map()]
  def finish(%__MODULE__{buf: buf}) do
    if byte_size(buf) > 0 and commit_start?(buf, 0) do
      [parse_commit_text(binary_part(buf, 1, byte_size(buf) - 1))]
    else
      []
    end
  end

  @doc "Pure: parse a complete buffer into all its commit records."
  @spec parse(binary()) :: [map()]
  def parse(buf) do
    starts = commit_starts(buf)

    case starts do
      [] ->
        []

      _ ->
        bounds = starts ++ [byte_size(buf)]

        bounds
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] ->
          parse_commit_text(binary_part(buf, from + 1, to - from - 1))
        end)
    end
  end

  ## Internals

  # All byte offsets in `buf` that begin a commit header.
  defp commit_starts(buf) do
    buf
    |> :binary.matches(<<0>>)
    |> Enum.map(fn {pos, _len} -> pos end)
    |> Enum.filter(&commit_start?(buf, &1))
  end

  # Is there a commit-header start at byte offset `i`?
  # A header is: NUL, hex SHA (40/64), NUL, then a non-empty all-digits epoch
  # (terminated by another NUL). The epoch check disambiguates a commit-start NUL
  # from a parent SHA's trailing NUL (a parent is followed by another hex SHA or
  # NUL, never a decimal epoch).
  defp commit_start?(buf, i) do
    with true <- :binary.at(buf, i) == 0,
         j when is_integer(j) <- next_nul(buf, i + 1),
         len = j - (i + 1),
         true <- len == 40 or len == 64,
         true <- all_bytes?(buf, i + 1, j, &hex_byte?/1),
         e when is_integer(e) <- next_nul(buf, j + 1),
         true <- e > j + 1,
         true <- all_bytes?(buf, j + 1, e, &digit_byte?/1) do
      true
    else
      _ -> false
    end
  end

  # Offset of the next NUL at or after `from`, or nil if none (need more bytes).
  defp next_nul(buf, from) do
    case :binary.match(buf, <<0>>, scope: {from, byte_size(buf) - from}) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp all_bytes?(buf, from, to, fun) do
    buf
    |> binary_part(from, to - from)
    |> :binary.bin_to_list()
    |> Enum.all?(fun)
  end

  defp hex_byte?(c), do: (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f)
  defp digit_byte?(c), do: c >= ?0 and c <= ?9

  # Parse the text of one commit (leading NUL already stripped).
  defp parse_commit_text(text) do
    {header_text, body_text} =
      case :binary.split(text, "\n") do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    fields = :binary.split(header_text, <<0>>, [:global])

    case fields do
      [sha, at, name, email | _] ->
        unless sha_valid?(sha), do: raise(ParseError, "invalid sha: #{inspect(sha)}")

        committed_at =
          case Integer.parse(at) do
            {n, ""} -> n
            _ -> raise ParseError, "invalid timestamp: #{inspect(at)}"
          end

        parents = (Enum.at(fields, 4) || "") |> String.trim()
        parent_count = if parents == "", do: 0, else: length(String.split(parents, " "))

        {files, renames} = parse_entries(body_text)

        %{
          sha: sha,
          committed_at: committed_at,
          author_name: name,
          author_email: email,
          parent_count: parent_count,
          files: files,
          renames: renames
        }

      _ ->
        raise ParseError, "malformed commit header: #{inspect(header_text)}"
    end
  end

  defp sha_valid?(sha) do
    byte_size(sha) in [40, 64] and
      sha |> :binary.bin_to_list() |> Enum.all?(&hex_byte?/1)
  end

  # Numstat entries are NUL-separated; trailing separators yield empty tokens.
  defp parse_entries(body_text) do
    tokens = :binary.split(body_text, <<0>>, [:global])
    {files, renames} = do_entries(tokens, [], [])
    {Enum.reverse(files), Enum.reverse(renames)}
  end

  defp do_entries([], files, renames), do: {files, renames}
  defp do_entries(["" | rest], files, renames), do: do_entries(rest, files, renames)

  defp do_entries([tok | rest], files, renames) do
    {added, deleted, path} = split_numstat(tok)

    if path != "" do
      # Normal / binary entry: path is the remainder (may itself contain tabs).
      do_entries(rest, [%{path: path, added: added, deleted: deleted} | files], renames)
    else
      # Rename: the next two non-empty tokens are old then new path.
      {old_path, rest1} = next_token(rest)
      {new_path, rest2} = next_token(rest1)
      file = %{path: new_path, added: added, deleted: deleted}
      rename = %{old_path: old_path, new_path: new_path, similarity: nil}
      do_entries(rest2, [file | files], [rename | renames])
    end
  end

  defp split_numstat(tok) do
    case String.split(tok, "\t", parts: 3) do
      [a, d, rest] -> {parse_count(a), parse_count(d), rest}
      _ -> raise ParseError, "malformed numstat entry: #{inspect(tok)}"
    end
  end

  defp parse_count("-"), do: nil

  defp parse_count(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> raise ParseError, "invalid numstat count: #{inspect(s)}"
    end
  end

  defp next_token([]), do: raise(ParseError, "rename entry missing a path")
  defp next_token(["" | rest]), do: next_token(rest)
  defp next_token([tok | rest]), do: {tok, rest}
end
