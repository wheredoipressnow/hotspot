defmodule Hotspot.Analysis.DefectsPureTest do
  use ExUnit.Case, async: true

  alias Hotspot.Analysis.Defects

  describe "fix?/1 and revert?/1" do
    test "recognizes fix keywords and issue references" do
      assert Defects.fix?("Fix the parser")
      assert Defects.fix?("bugfix: off-by-one")
      assert Defects.fix?("resolves the crash")
      assert Defects.fix?("address #123")
      refute Defects.fix?("Add a feature")
      refute Defects.fix?(nil)
    end

    test "recognizes reverts only at the start" do
      assert Defects.revert?("Revert \"bad change\"")
      refute Defects.revert?("this reverts nothing in particular")
      refute Defects.revert?("Add revert button")
    end
  end
end
