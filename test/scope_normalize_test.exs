defmodule PhoenixKitBoards.ScopeNormalizeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Boards

  test "strings, integers and atoms all name a place" do
    assert Boards.normalize_scope({"order", "A-17"}) == {:ok, {"order", "A-17"}}
    assert Boards.normalize_scope({"order", 1001}) == {:ok, {"order", "1001"}}
    assert Boards.normalize_scope({:order, 1001}) == {:ok, {"order", "1001"}}
    assert Boards.normalize_scope({"project", :alpha}) == {:ok, {"project", "alpha"}}
  end

  test "nil is the boards that belong nowhere" do
    assert Boards.normalize_scope(nil) == {:ok, nil}
  end

  test "anything that does not name a place is an error — above all a missing id" do
    for bad <- [
          {"order", nil},
          {nil, "x"},
          {"", "x"},
          {"order", ""},
          {true, "x"},
          {"order", false},
          {"order", 1.5},
          {"order", %{}},
          {"order", ["a"]},
          {"order"},
          {"a", "b", "c"},
          "order",
          5,
          []
        ] do
      assert Boards.normalize_scope(bad) == :error, "accepted #{inspect(bad)}"
    end
  end

  test "the query functions refuse a bad place plainly instead of widening it" do
    assert_raise ArgumentError, ~r/not a place/, fn ->
      Boards.list_for_scope({"order", nil}, nil)
    end

    assert_raise ArgumentError, ~r/not a place/, fn -> Boards.scope_topic({"order", nil}) end
  end

  test "a topic is the same whichever way the id was written" do
    assert Boards.scope_topic({"order", 1001}) == Boards.scope_topic({:order, "1001"})
  end
end
