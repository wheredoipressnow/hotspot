defmodule HotspotRunner.XrayParser do
  @moduledoc """
  Parses the output of the X-Ray single-file patch log (see
  `HotspotRunner.Git.file_log_args/2`) into per-hunk change events attributed to
  the hunk's git diff **section heading** (the changed region). The field is
  named `:function` for brevity, but it is whatever git's active diff driver
  reports: a real definition where a driver exists, an approximate
  nearest-definition line otherwise.

  ## Framing

    * A commit header line begins with RS (`0x1e`):
      `RS sha US epoch US name US email US parents`.
    * Patch text follows. We read only **hunk headers**:
      `@@ -A,B +C,D @@ <section heading>`. `B`/`D` default to `1` when the
      `,count` part is omitted; churn for the hunk is `B + D` (deleted + added).
    * The section heading is the enclosing region as computed by git's diff
      driver **at that revision**. This sidesteps the moving-target problem (no
      need to parse file revisions ourselves). Hunks with no heading fall into
      `#{inspect("(unattributed)")}`.

  All other lines (`diff --git`, `index`, `---`/`+++`, the `+`/`-` body) are
  ignored: with `--unified=0` the `@@` ranges already carry every count we need.

  Output is a flat list of events, oldest commit first:

      %{function: name, churn: deleted + added, author: email,
        committed_at: epoch, sha: sha}

  Grouping and metric reduction happen in `HotspotRunner.Xray`.
  """

  @unattributed "(unattributed)"

  @rs "\x1e"
  @us "\x1f"

  @type event :: %{
          function: String.t(),
          churn: non_neg_integer,
          author: String.t(),
          committed_at: integer,
          sha: String.t()
        }

  @doc "Parse a full X-Ray patch-log buffer into per-hunk events."
  @spec parse(binary) :: [event]
  def parse(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, []}, &reduce_line/2)
    |> elem(1)
    |> Enum.reverse()
  end

  # A commit header resets the "current commit" carried into following hunks.
  defp reduce_line(@rs <> rest, {_commit, events}) do
    {parse_header(rest), events}
  end

  # A hunk under a known commit emits one event; ignore hunks with no commit
  # context (shouldn't happen) and every non-hunk line. Content lines under
  # `--unified=0` are prefixed with `+`/`-`/space, so only a real hunk header
  # begins with an unprefixed `@@ `.
  defp reduce_line("@@ " <> rest, {commit, events} = acc) when not is_nil(commit) do
    case parse_hunk(rest) do
      {churn, heading} -> {commit, [event(commit, churn, heading) | events]}
      :error -> acc
    end
  end

  defp reduce_line(_line, acc), do: acc

  defp parse_header(rest) do
    case String.split(rest, @us) do
      [sha, at, _name, email | _] -> %{sha: sha, author: email, committed_at: to_int(at)}
      _ -> nil
    end
  end

  # `rest` is everything after the leading `@@ `: "-A,B +C,D @@ heading".
  defp parse_hunk(rest) do
    case String.split(rest, " @@", parts: 2) do
      [ranges, tail] -> {churn(ranges), function_name(tail)}
      _ -> :error
    end
  end

  # ranges = "-A,B +C,D" (the ",B"/",D" parts are omitted for single lines).
  defp churn(ranges) do
    case String.split(ranges, " ", parts: 2) do
      [del, add] -> range_count(del) + range_count(add)
      _ -> 0
    end
  end

  # Drop the leading +/- sign; an omitted ",count" means a single line.
  defp range_count(<<_sign::utf8, rest::binary>>) do
    case String.split(rest, ",", parts: 2) do
      [_start] -> 1
      [_start, count] -> to_int(count)
    end
  end

  defp range_count(_), do: 0

  defp function_name(tail) do
    case String.trim(tail) do
      "" -> @unattributed
      name -> name
    end
  end

  defp event(commit, churn, heading) do
    %{
      function: heading,
      churn: churn,
      author: commit.author,
      committed_at: commit.committed_at,
      sha: commit.sha
    }
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
