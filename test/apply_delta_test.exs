defmodule PhoenixKitBoards.ApplyDeltaTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Boards

  defp shape(id, x \\ 0), do: %{"uuid" => id, "kind" => "rectangle", "geometry" => %{"x" => x}}
  defp ids(list), do: Enum.map(list, & &1["uuid"])
  defp edit(base, new), do: Boards.diff(base, new)

  describe "apply_delta/2" do
    test "an edit lands on a board that has moved on since the editor last looked" do
      base = [shape("a")]
      stored = [shape("a"), shape("peer")]
      delta = edit(base, [shape("a"), shape("mine")])

      assert ids(Boards.apply_delta(stored, delta)) == ["a", "peer", "mine"]
    end

    test "two editors' edits applied in either order give the same board" do
      base = [shape("a"), shape("b")]
      one = edit(base, [shape("a", 5), shape("b"), shape("one")])
      two = edit(base, [shape("b"), shape("a"), shape("two")] |> List.delete_at(1))

      forward = base |> Boards.apply_delta(one) |> Boards.apply_delta(two)
      backward = base |> Boards.apply_delta(two) |> Boards.apply_delta(one)

      assert Enum.sort(ids(forward)) == Enum.sort(ids(backward))
      assert "one" in ids(forward) and "two" in ids(forward)
    end

    test "applying the same delta twice changes nothing" do
      base = [shape("a")]
      delta = edit(base, [shape("a", 9), shape("b")])
      once = Boards.apply_delta(base, delta)

      assert Boards.apply_delta(once, delta) == once
    end

    test "a delete of a shape somebody already deleted is ignored" do
      delta = edit([shape("a"), shape("b")], [shape("a")])
      assert ids(Boards.apply_delta([shape("a")], delta)) == ["a"]
    end

    test "an update to a shape somebody deleted does not bring it back" do
      delta = edit([shape("a"), shape("b")], [shape("a"), shape("b", 7)])
      assert ids(Boards.apply_delta([shape("a")], delta)) == ["a"]
    end

    test "the editor's own update replaces the stored shape" do
      delta = edit([shape("a")], [shape("a", 42)])
      assert [%{"geometry" => %{"x" => 42}}] = Boards.apply_delta([shape("a")], delta)
    end

    test "a reorder is imposed on the shapes it names and leaves a stranger where it was" do
      base = [shape("a"), shape("b")]
      delta = edit(base, [shape("b"), shape("a")])

      assert ids(Boards.apply_delta([shape("a"), shape("peer"), shape("b")], delta)) ==
               ["b", "peer", "a"]
    end

    test "a new shape is placed where the editor put it" do
      base = [shape("a"), shape("b")]
      delta = edit(base, [shape("new"), shape("a"), shape("b")])

      assert ids(Boards.apply_delta(base, delta)) == ["new", "a", "b"]
    end

    test "an empty edit changes nothing" do
      list = [shape("a"), shape("b")]
      assert Boards.apply_delta(list, edit(list, list)) == list
    end
  end
end
