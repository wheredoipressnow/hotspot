defmodule HotspotRunner.BlameTest do
  use ExUnit.Case, async: true

  alias HotspotRunner.Blame

  # Captured-shape `git blame --line-porcelain` output: two commits, a blank line,
  # and a same-commit group (line 3) that repeats full info (as --line-porcelain does).
  defp fixture do
    """
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 2
    author Ada Lovelace
    author-mail <ada@example.com>
    author-time 1000
    author-tz +0000
    summary Add module
    filename foo.ex
    \tdefmodule Foo do
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2 2
    author Ada Lovelace
    author-mail <ada@example.com>
    author-time 1000
    summary Add module
    filename foo.ex
    \t
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 3 3 1
    author Bob Bits
    author-mail <bob@example.com>
    author-time 2000
    summary Fix the bug
    filename foo.ex
    \t  def go, do: :ok
    """
  end

  test "one entry per line, in file order" do
    lines = Blame.parse(fixture())
    assert Enum.map(lines, & &1.line) == [1, 2, 3]
  end

  test "carries sha, author, time and the change reason (summary)" do
    [l1, _l2, l3] = Blame.parse(fixture())

    assert l1.sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    assert l1.author == "Ada Lovelace"
    assert l1.time == 1000
    assert l1.summary == "Add module"

    assert l3.author == "Bob Bits"
    assert l3.time == 2000
    assert l3.summary == "Fix the bug"
  end

  test "preserves code content including leading whitespace and blank lines" do
    [l1, l2, l3] = Blame.parse(fixture())
    assert l1.code == "defmodule Foo do"
    assert l2.code == ""
    assert l3.code == "  def go, do: :ok"
  end

  test "empty output yields no lines" do
    assert Blame.parse("") == []
  end
end
