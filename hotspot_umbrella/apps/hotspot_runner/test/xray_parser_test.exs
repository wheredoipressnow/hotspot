defmodule HotspotRunner.XrayParserTest do
  use ExUnit.Case, async: true

  alias HotspotRunner.XrayParser

  @rs "\x1e"
  @us "\x1f"

  defp header(sha, at, name, email, parents \\ "") do
    @rs <> Enum.join([sha, at, name, email, parents], @us)
  end

  # A captured-shape `git log -p --unified=0` stream: two commits over one file,
  # with headings, a count-omitted hunk, and a headingless hunk.
  setup do
    output =
      [
        header("aaa1", "1000", "Ada", "ada@example.com"),
        "diff --git a/foo.ex b/foo.ex",
        "--- a/foo.ex",
        "+++ b/foo.ex",
        "@@ -1,2 +1,3 @@ def hello do",
        "-old",
        "+new1",
        "+new2",
        "@@ -10 +11,0 @@ def bye do",
        "-removed",
        header("bbb2", "2000", "Bob", "bob@example.com", "aaa1"),
        "diff --git a/foo.ex b/foo.ex",
        "@@ -5,1 +5,4 @@ def hello do",
        "-x",
        "+a",
        "+b",
        "+c",
        "@@ -20 +20 @@",
        "-y",
        "+z"
      ]
      |> Enum.join("\n")

    %{events: XrayParser.parse(output)}
  end

  test "emits one event per hunk, in stream order", %{events: events} do
    assert length(events) == 4

    assert Enum.map(events, & &1.function) ==
             ["def hello do", "def bye do", "def hello do", "(unattributed)"]
  end

  test "churn is deleted + added from the hunk ranges", %{events: events} do
    [hello1, bye, hello2, unattr] = events
    # @@ -1,2 +1,3 @@  -> 2 + 3
    assert hello1.churn == 5
    # @@ -10 +11,0 @@  -> omitted count is 1 deleted, 0 added
    assert bye.churn == 1
    # @@ -5,1 +5,4 @@  -> 1 + 4
    assert hello2.churn == 5
    # @@ -20 +20 @@    -> both omitted, 1 + 1
    assert unattr.churn == 2
  end

  test "carries the commit's author, timestamp and sha onto each hunk", %{events: events} do
    [hello1 | _] = events
    assert hello1.author == "ada@example.com"
    assert hello1.committed_at == 1000
    assert hello1.sha == "aaa1"

    unattr = List.last(events)
    assert unattr.author == "bob@example.com"
    assert unattr.committed_at == 2000
    assert unattr.sha == "bbb2"
  end

  test "headingless hunks fall into the unattributed bucket", %{events: events} do
    assert Enum.any?(events, &(&1.function == "(unattributed)"))
  end

  test "empty output yields no events" do
    assert XrayParser.parse("") == []
  end
end
