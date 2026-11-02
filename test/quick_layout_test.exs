defmodule PhoenixKitBoards.QuickLayoutTest do
  @moduledoc """
  How a paste of several pictures (and some text) is laid out on one board.
  Pure: no storage, no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.{Boards, Quick}

  defp stored(n, size \\ %{width: 1600, height: 900}),
    do: for(i <- 1..n, do: {size, "/file/#{i}"})

  defp box(%{"geometry" => g}), do: {g["x"], g["y"], g["x"] + g["w"], g["y"] + g["h"]}

  defp overlap?({ax1, ay1, ax2, ay2}, {bx1, by1, bx2, by2}),
    do: ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2

  defp inside_canvas?({x1, y1, x2, y2}) do
    {w, h} = Boards.canvas_size()
    x1 >= 0 and y1 >= 0 and x2 <= w and y2 <= h
  end

  for n <- 1..8 do
    test "#{n} picture(s): all on the canvas, none on top of another" do
      shapes = Quick.layout(stored(unquote(n)), "")
      boxes = Enum.map(shapes, &box/1)

      assert length(shapes) == unquote(n)
      assert Enum.all?(boxes, &inside_canvas?/1)

      for a <- boxes, b <- boxes, a != b, do: refute(overlap?(a, b))
    end
  end

  test "with a note: the note is above the pictures, and nothing collides" do
    shapes = Quick.layout(stored(4), "Bathroom tiles")
    [note | pictures] = shapes

    assert note["kind"] == "text"
    assert Enum.all?(pictures, &(&1["kind"] == "image"))

    {_, _, _, note_bottom} = box(note)
    assert Enum.all?(pictures, fn p -> elem(box(p), 1) >= note_bottom end)
    assert Enum.all?(shapes, &inside_canvas?(box(&1)))
  end

  test "a very long note still leaves the pictures room" do
    long = Enum.map_join(1..60, "\n", fn i -> "line number #{i} of a long note" end)
    shapes = Quick.layout(stored(2), long)

    pictures = Enum.filter(shapes, &(&1["kind"] == "image"))
    {_, canvas_h} = Boards.canvas_size()

    assert Enum.all?(pictures, fn p ->
             {_, y1, _, y2} = box(p)
             y2 - y1 > 500 and y1 < canvas_h * 0.8
           end)
  end

  test "pictures keep their proportions" do
    [wide, tall] =
      Quick.layout([{%{width: 1600, height: 900}, "/w"}, {%{width: 900, height: 1600}, "/t"}], "")

    assert_in_delta wide["geometry"]["w"] / wide["geometry"]["h"], 1600 / 900, 0.01
    assert_in_delta tall["geometry"]["w"] / tall["geometry"]["h"], 900 / 1600, 0.01
  end

  test "a picture of unknown size still gets a place" do
    assert [%{"geometry" => %{"w" => w, "h" => h}}] =
             Quick.layout(stored(1, %{width: nil, height: nil}), "")

    assert w > 0 and h > 0
  end
end
