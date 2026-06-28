defmodule Hotspot.Analysis.OwnershipPureTest do
  use ExUnit.Case, async: true

  alias Hotspot.Analysis.Ownership

  describe "bus_factor?/2" do
    test "flags a file one author dominates (multi-author, share over threshold)" do
      assert Ownership.bus_factor?(%{ownership: 0.7, author_count: 3}, 0.6)
    end

    test "does not flag a sole-author file (no factor to lose)" do
      refute Ownership.bus_factor?(%{ownership: 1.0, author_count: 1}, 0.6)
    end

    test "does not flag a well-shared file" do
      refute Ownership.bus_factor?(%{ownership: 0.4, author_count: 4}, 0.6)
    end
  end

  describe "abandoned?/3" do
    test "flags a file whose owner has not committed since the cutoff" do
      activity = %{"ada@x" => 100}
      assert Ownership.abandoned?(%{main_author: "ada@x"}, activity, 200)
    end

    test "does not flag a file whose owner is still active" do
      activity = %{"ada@x" => 300}
      refute Ownership.abandoned?(%{main_author: "ada@x"}, activity, 200)
    end

    test "a churn-free file (no owner) is never abandoned" do
      refute Ownership.abandoned?(%{main_author: nil}, %{}, 200)
    end
  end
end
