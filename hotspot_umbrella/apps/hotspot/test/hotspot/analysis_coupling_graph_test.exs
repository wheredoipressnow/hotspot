defmodule Hotspot.AnalysisCouplingGraphTest do
  use Hotspot.IntegrationCase

  alias Hotspot.Analysis

  setup do
    seed_coupling_repo!()
    :ok
  end

  defp busiest_path do
    [%{path: path} | _] = Analysis.top_hotspots(%{scope: "files", limit: 1})
    path
  end

  describe "coupling_graph/2" do
    test "returns a well-formed, root-anchored, undirected graph" do
      path = busiest_path()
      %{root: root, nodes: nodes, edges: edges} = Analysis.coupling_graph(path)

      assert root == path
      assert is_list(nodes) and is_list(edges)

      # The root is always a node, at depth 0.
      assert Enum.any?(nodes, &(&1.id == root and &1.depth == 0))

      ids = MapSet.new(nodes, & &1.id)

      for n <- nodes do
        assert is_binary(n.id)
        assert is_integer(n.degree) and n.degree >= 0
        assert is_integer(n.depth) and n.depth >= 0
      end

      for e <- edges do
        # Endpoints exist as nodes, the edge is not a self-loop, and is normalised
        # (source <= target) so it can't appear twice in mirrored form.
        assert e.source in ids and e.target in ids
        assert e.source != e.target
        assert e.source <= e.target
        assert is_float(e.weight) and e.weight > 0.0 and e.weight <= 1.0
      end

      # Undirected: at most one edge per unordered pair.
      pairs = Enum.map(edges, &{&1.source, &1.target})
      assert pairs == Enum.uniq(pairs)

      # degree is exactly the incident-edge count.
      expected =
        Enum.reduce(edges, %{}, fn e, acc ->
          acc |> Map.update(e.source, 1, &(&1 + 1)) |> Map.update(e.target, 1, &(&1 + 1))
        end)

      for n <- nodes, do: assert(n.degree == Map.get(expected, n.id, 0))
    end

    test "depth controls reach: deeper never yields fewer nodes" do
      path = busiest_path()
      d1 = Analysis.coupling_graph(path, depth: 1)
      d2 = Analysis.coupling_graph(path, depth: 2)

      # Depth 1 only reaches the root's direct neighbours.
      for n <- d1.nodes, do: assert(n.depth <= 1)

      assert MapSet.subset?(
               MapSet.new(d1.nodes, & &1.id),
               MapSet.new(d2.nodes, & &1.id)
             )
    end

    test ":max_nodes caps the graph" do
      path = busiest_path()
      g = Analysis.coupling_graph(path, depth: 3, max_nodes: 5)
      assert length(g.nodes) <= 5
    end

    test "a path that never changed yields a lone root node" do
      g = Analysis.coupling_graph("does/not/exist.zzz")
      assert g.root == "does/not/exist.zzz"
      assert g.edges == []
      assert Enum.map(g.nodes, & &1.id) == ["does/not/exist.zzz"]
    end
  end
end
