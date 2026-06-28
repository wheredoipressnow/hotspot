defmodule Hotspot.Analysis.PathIndex do
  @moduledoc """
  Flat path list backing the fuzzy finder ("go to file/folder"). Returns every
  file touched in history plus its ancestor folders, so the palette can jump to a
  file (open its X-Ray) or a folder (set the scope).

  Honors the same `include_removed` and time-window (`:since`/`:until`) params as
  the tree and list, so the index mirrors what the map shows: with
  `include_removed: false` it folds renames and drops paths gone from HEAD (see
  `Hotspot.Analysis.Renames` and `Hotspot.Analysis.Tracked`).
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.{Renames, Tracked, Window}
  alias Hotspot.Storage.{Commit, FileChange}

  @type entry :: %{path: String.t(), kind: :file | :folder}

  @doc "Files and folders for the open db, as `[%{path, kind}]` (files first)."
  @spec list(map) :: [entry]
  def list(params \\ %{}) do
    include_removed = Map.get(params, :include_removed, true)

    files =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: not is_nil(f.added),
        distinct: true,
        select: f.path
      )
      |> Window.restrict(params)
      |> repo().all()
      |> resolve(include_removed)

    folders = files |> Enum.flat_map(&ancestors/1) |> Enum.uniq()

    Enum.map(files, &%{path: &1, kind: :file}) ++
      Enum.map(folders, &%{path: &1, kind: :folder})
  end

  # With include_removed the raw paths stand; otherwise fold renames onto their
  # terminal path and keep only those still present at HEAD.
  defp resolve(paths, true), do: Enum.uniq(paths)

  defp resolve(paths, false) do
    rename = Renames.map()

    paths
    |> Enum.map(&%{path: Renames.resolve(rename, &1)})
    |> Tracked.filter()
    |> Enum.map(& &1.path)
    |> Enum.uniq()
  end

  # "lib/a/b.ex" -> ["lib", "lib/a"]
  defp ancestors(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.scan(&"#{&2}/#{&1}")
  end

  defp repo, do: Application.get_env(:hotspot, :repo, Repo)
end
