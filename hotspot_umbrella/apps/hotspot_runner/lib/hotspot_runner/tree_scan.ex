defmodule HotspotRunner.TreeScan do
  @moduledoc """
  One-pass scan of a ref's tree (not its history) producing the per-file size and
  indentation metrics stored in `tracked_file`.

  Lists the ref's blobs, reads their contents in a single `git cat-file --batch`
  pass, and runs `HotspotRunner.Indent.metrics/1` over each. Binary blobs keep
  their path with `nil` metric fields, so the snapshot still records every tracked
  file.
  """

  alias HotspotRunner.{Git, Indent}

  @type entry :: %{
          path: String.t(),
          loc: non_neg_integer | nil,
          indent_total: non_neg_integer | nil,
          indent_max: non_neg_integer | nil
        }

  @doc "Metric entries for every blob tracked at `ref`."
  @spec scan(String.t(), String.t()) :: [entry]
  def scan(cwd, ref) do
    blobs = git().tree_blobs(cwd, ref)
    contents = git().read_blobs(cwd, Enum.map(blobs, fn {sha, _path} -> sha end))

    Enum.map(blobs, fn {sha, path} ->
      entry(path, Map.get(contents, sha))
    end)
  end

  # No content (unreadable blob) or binary content both yield nil metrics.
  defp entry(path, content) when is_binary(content) do
    case Indent.metrics(content) do
      %{loc: loc, indent_total: total, indent_max: max} ->
        %{path: path, loc: loc, indent_total: total, indent_max: max}

      nil ->
        %{path: path, loc: nil, indent_total: nil, indent_max: nil}
    end
  end

  defp entry(path, nil), do: %{path: path, loc: nil, indent_total: nil, indent_max: nil}

  defp git, do: Application.get_env(:hotspot_runner, :git, Git)
end
