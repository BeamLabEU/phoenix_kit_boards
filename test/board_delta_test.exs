defmodule PhoenixKitBoards.BoardDeltaTest do
  @moduledoc """
  The annotation delta is what keeps collaborators in sync, and position in
  the list is z-order — etcher paints in array order. A diff keyed only by
  uuid reports a pure reshuffle as "nothing changed", which meant bringing a
  caption in front of an image was neither saved nor sent to the other
  viewers. These pin that.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardLive

  defp shape(uuid, opts \\ []) do
    %{
      "uuid" => uuid,
      "kind" => Keyword.get(opts, :kind, "rectangle"),
      "geometry" => Keyword.get(opts, :geometry, %{"x" => 0, "y" => 0})
    }
  end

  describe "diff/2 — membership" do
    test "reports an added shape" do
      delta = BoardLive.diff([shape("a")], [shape("a"), shape("b")])

      assert [%{"uuid" => "b"}] = delta["created"]
      assert delta["updated"] == []
      assert delta["deleted"] == []
      refute BoardLive.empty_delta?(delta)
    end

    test "reports a removed shape" do
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("a")])

      assert delta["deleted"] == ["b"]
      assert delta["created"] == []
      refute BoardLive.empty_delta?(delta)
    end

    test "reports a changed shape" do
      delta =
        BoardLive.diff(
          [shape("a", geometry: %{"x" => 0})],
          [shape("a", geometry: %{"x" => 40})]
        )

      assert [%{"uuid" => "a", "geometry" => %{"x" => 40}}] = delta["updated"]
      refute BoardLive.empty_delta?(delta)
    end

    test "an identical list is a no-op" do
      list = [shape("a"), shape("b")]

      assert BoardLive.empty_delta?(BoardLive.diff(list, list))
    end
  end

  describe "diff/2 — z-order" do
    # The regression this whole feature rests on. Same shapes, same contents,
    # different order: previously created/updated/deleted were all empty, so
    # empty_delta? said true and the reorder was dropped on the floor.
    test "a pure reorder is a real change" do
      old = [shape("a"), shape("b")]
      new = [shape("b"), shape("a")]

      delta = BoardLive.diff(old, new)

      assert delta["created"] == []
      assert delta["updated"] == []
      assert delta["deleted"] == []
      assert delta["reordered"] == true
      refute BoardLive.empty_delta?(delta), "a reorder must not be treated as a no-op"
    end

    test "carries the full order so the client can reimpose it" do
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("b"), shape("a")])

      assert delta["order"] == ["b", "a"]
    end

    test "order rides along on every delta, not only reorders" do
      # The client applies updates by removing and re-adding, and re-adding
      # appends — so it needs the authoritative order even when the change
      # itself was not a reorder.
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("a"), shape("b"), shape("c")])

      assert delta["order"] == ["a", "b", "c"]
    end

    # Adding or removing shifts every later index, which must not be mistaken
    # for a reshuffle — the create/delete is already reported on its own.
    test "an append is not counted as a reorder" do
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("a"), shape("b"), shape("c")])

      assert delta["reordered"] == false
    end

    test "a prepend is not counted as a reorder" do
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("c"), shape("a"), shape("b")])

      assert delta["reordered"] == false
    end

    test "a deletion from the middle is not counted as a reorder" do
      delta = BoardLive.diff([shape("a"), shape("b"), shape("c")], [shape("a"), shape("c")])

      assert delta["deleted"] == ["b"]
      assert delta["reordered"] == false
    end

    test "a reorder is still detected alongside a create" do
      delta = BoardLive.diff([shape("a"), shape("b")], [shape("b"), shape("a"), shape("c")])

      assert [%{"uuid" => "c"}] = delta["created"]
      assert delta["reordered"] == true
      assert delta["order"] == ["b", "a", "c"]
    end

    test "shapes without a uuid are ignored rather than crashing the order" do
      delta = BoardLive.diff([shape("a")], [%{"kind" => "text"}, shape("a")])

      assert delta["order"] == ["a"]
      assert delta["reordered"] == false
    end
  end
end
