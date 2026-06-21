defmodule HotspotRunner.IndentTest do
  use ExUnit.Case, async: true

  alias HotspotRunner.Indent

  test "counts non-blank lines and sums leading-space columns" do
    src = "a\n  b\n    c\n"
    assert Indent.metrics(src) == %{loc: 3, indent_total: 0 + 2 + 4, indent_max: 4}
  end

  test "blank and whitespace-only lines are ignored" do
    src = "a\n\n   \n  b\n"
    assert Indent.metrics(src) == %{loc: 2, indent_total: 2, indent_max: 2}
  end

  test "tabs expand to the next tab stop" do
    # one tab => 4 columns; tab then two spaces => 6.
    src = "\ta\n\t  b\n"
    assert Indent.metrics(src) == %{loc: 2, indent_total: 4 + 6, indent_max: 6}
  end

  test "a space then a tab still aligns to the tab stop" do
    # space (col 1) then tab advances to col 4.
    assert Indent.metrics(" \tx\n") == %{loc: 1, indent_total: 4, indent_max: 4}
  end

  test "empty content has zero metrics" do
    assert Indent.metrics("") == %{loc: 0, indent_total: 0, indent_max: 0}
  end

  test "binary content (NUL byte) yields nil" do
    assert Indent.metrics(<<?a, 0, ?b>>) == nil
  end
end
