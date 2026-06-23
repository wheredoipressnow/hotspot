defmodule Hotspot.Analysis.Coupling do
  @moduledoc """
  Temporal (logical) coupling: the files that most often change in the same
  commits as a given file. High co-change means the two are coupled in practice
  even with no direct code reference: a hidden dependency or a refactoring smell.

  For non-merge commits only:

      coupling = shared_commits / commits_touching(path)

  i.e. "when `path` changes, how often does the other file change too". Renames
  are not folded, so a file's pre-rename path counts separately.
  """
  import Ecto.Query
  alias Hotspot.Repo
  alias Hotspot.Analysis.Window
  alias Hotspot.Storage.{Commit, FileChange}

  @type coupled :: %{path: String.t(), shared_commits: non_neg_integer, coupling: float}

  @doc """
  Top files co-changing with `path`, by coupling ratio (desc). `opts`: `:limit`
  (default 15), `:min_shared` (default 2, drops one-off co-changes as noise),
  `:since` / `:until` (epoch bounds restricting the commits considered).
  """
  @spec top(String.t(), keyword) :: [coupled]
  def top(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 15)
    min_shared = Keyword.get(opts, :min_shared, 2)

    # Distinct non-merge commits that touched `path`, within the time window.
    shas =
      from(f in FileChange,
        join: c in Commit,
        on: c.sha == f.commit_sha,
        where: f.path == ^path and c.parent_count < 2,
        distinct: true,
        select: f.commit_sha
      )
      |> Window.restrict(Keyword.get(opts, :since), Keyword.get(opts, :until))

    denom = Repo.one(from(s in subquery(shas), select: count()))

    if denom in [nil, 0] do
      []
    else
      from(f in FileChange,
        where: f.commit_sha in subquery(shas) and f.path != ^path,
        group_by: f.path,
        select: %{path: f.path, shared_commits: count(f.commit_sha, :distinct)}
      )
      |> Repo.all()
      |> Enum.filter(&(&1.shared_commits >= min_shared))
      |> Enum.map(&Map.put(&1, :coupling, Float.round(&1.shared_commits / denom, 2)))
      |> Enum.sort_by(&{&1.coupling, &1.shared_commits}, :desc)
      |> Enum.take(limit)
    end
  end

  @type node_t :: %{id: String.t(), degree: non_neg_integer, depth: non_neg_integer}
  @type edge_t :: %{source: String.t(), target: String.t(), weight: float}
  @type graph_t :: %{root: String.t(), nodes: [node_t], edges: [edge_t]}

  @doc """
  A recursively-expanded coupling graph rooted at `path`, for the force-directed
  ("cloud") view. Each file's coupling is expanded up to `:depth` hops. Edges are
  undirected pairs carrying the strongest coupling seen between the two files; each
  node carries its `degree` (incident edge count) and `depth` (hops from the root).

  `opts`: `:depth` (default 2, clamped to 1..3), `:breadth` (top coupled files to
  follow per node, default 8), `:min_shared` (passed to `top/2`, default 2),
  `:max_nodes` (hard cap on distinct files, default 120, bounding query volume).
  """
  @spec graph(String.t(), keyword) :: graph_t
  def graph(path, opts \\ []) do
    depth = opts |> Keyword.get(:depth, 2) |> clamp(1, 3)
    breadth = Keyword.get(opts, :breadth, 8)

    top_opts = [
      limit: breadth,
      min_shared: Keyword.get(opts, :min_shared, 2),
      since: Keyword.get(opts, :since),
      until: Keyword.get(opts, :until)
    ]

    max_nodes = Keyword.get(opts, :max_nodes, 120)

    # `visited` maps path -> depth (also our expansion memo); `edges` maps the
    # sorted {a, b} pair -> strongest coupling weight seen for it.
    {_visited, edges} =
      expand([{path, 0}], %{path => 0}, %{}, depth, top_opts, max_nodes)

    build(path, edges)
  end

  # BFS frontier. Pop a node; if it's within depth and we still have room, fetch its
  # coupled files, record undirected edges, and enqueue unseen neighbours.
  defp expand([], visited, edges, _depth, _top_opts, _max), do: {visited, edges}

  defp expand([{path, d} | rest], visited, edges, depth, top_opts, max) do
    if d >= depth do
      expand(rest, visited, edges, depth, top_opts, max)
    else
      neighbours = top(path, top_opts)

      {visited, edges, queue} =
        Enum.reduce(neighbours, {visited, edges, []}, fn n, {vis, eds, q} ->
          cond do
            # Already a node: just record the cross-edge (may close a cycle).
            Map.has_key?(vis, n.path) ->
              {vis, put_edge(eds, path, n), q}

            # No room for a new node; drop the edge so endpoints stay bounded.
            map_size(vis) >= max ->
              {vis, eds, q}

            true ->
              {Map.put(vis, n.path, d + 1), put_edge(eds, path, n), [{n.path, d + 1} | q]}
          end
        end)

      expand(rest ++ Enum.reverse(queue), visited, edges, depth, top_opts, max)
    end
  end

  # Materialise nodes from the edge set: degree is incident-edge count, depth is the
  # shortest hop distance from the root (root is depth 0, always present).
  defp build(root, edges) do
    edge_list =
      Enum.map(edges, fn {{a, b}, w} -> %{source: a, target: b, weight: w} end)

    degree =
      Enum.reduce(edge_list, %{}, fn %{source: a, target: b}, acc ->
        acc |> Map.update(a, 1, &(&1 + 1)) |> Map.update(b, 1, &(&1 + 1))
      end)

    depths = node_depths(root, edge_list)

    nodes =
      depths
      |> Enum.map(fn {id, depth} ->
        %{id: id, degree: Map.get(degree, id, 0), depth: depth}
      end)
      |> Enum.sort_by(& &1.depth)

    %{root: root, nodes: nodes, edges: edge_list}
  end

  # Shortest-path depth of every node from the root over the undirected edge set.
  defp node_depths(root, edge_list) do
    adj =
      Enum.reduce(edge_list, %{root => []}, fn %{source: a, target: b}, acc ->
        acc
        |> Map.update(a, [b], &[b | &1])
        |> Map.update(b, [a], &[a | &1])
      end)

    bfs_depths(:queue.from_list([root]), %{root => 0}, adj)
  end

  defp bfs_depths(queue, depths, adj) do
    case :queue.out(queue) do
      {:empty, _} ->
        depths

      {{:value, node}, rest} ->
        {queue, depths} =
          adj
          |> Map.get(node, [])
          |> Enum.reduce({rest, depths}, fn nbr, {q, ds} ->
            if Map.has_key?(ds, nbr),
              do: {q, ds},
              else: {:queue.in(nbr, q), Map.put(ds, nbr, ds[node] + 1)}
          end)

        bfs_depths(queue, depths, adj)
    end
  end

  defp put_edge(edges, from, neighbour) do
    Map.update(
      edges,
      edge_key(from, neighbour.path),
      neighbour.coupling,
      &max(&1, neighbour.coupling)
    )
  end

  defp edge_key(a, b) when a <= b, do: {a, b}
  defp edge_key(a, b), do: {b, a}

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)
end
