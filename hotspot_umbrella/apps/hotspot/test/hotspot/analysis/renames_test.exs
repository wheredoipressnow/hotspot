defmodule Hotspot.Analysis.RenamesTest do
  use ExUnit.Case, async: true

  alias Hotspot.Analysis.Renames

  test "an unmapped path resolves to itself" do
    assert Renames.resolve(%{}, "a.ex") == "a.ex"
  end

  test "a single hop resolves to the new path" do
    assert Renames.resolve(%{"old.ex" => "new.ex"}, "old.ex") == "new.ex"
  end

  test "a multi-hop chain resolves to the terminal path" do
    chain = %{"a.ex" => "b.ex", "b.ex" => "c.ex", "c.ex" => "d.ex"}
    assert Renames.resolve(chain, "a.ex") == "d.ex"
  end

  test "a self-edge terminates instead of looping" do
    assert Renames.resolve(%{"a.ex" => "a.ex"}, "a.ex") == "a.ex"
  end

  test "a cycle is guarded and does not loop forever" do
    cycle = %{"a.ex" => "b.ex", "b.ex" => "a.ex"}
    assert Renames.resolve(cycle, "a.ex") in ["a.ex", "b.ex"]
  end
end
