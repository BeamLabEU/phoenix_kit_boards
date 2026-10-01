defmodule PhoenixKitBoards.TouchSelectionTest do
  @moduledoc """
  A finger on a board draws, pans or presses. It never selects text.

  Reported from a phone: "I started tapping and moving and it selected the
  whole canvas like text… I can't replicate it consistently." The
  inconsistency is the clue. The canvas has refused selection since Fresco
  0.5, but it does not fill the page — there is a header above it and a
  gutter either side, about 17px wide on a 390px screen. A drag that starts a
  few pixels off the canvas is an ordinary text drag, and it takes the page
  with it. Whether it happens depends on where the finger landed, which is
  exactly how often it can be reproduced.

  Two properties, both cheap and both invisible until someone is holding a
  phone:

    * `select-none` on the page, so a drag beginning anywhere on it — gutter,
      header, the gap under the toolbar — selects nothing;
    * `-webkit-touch-callout: none`, which is the iOS half. A long press
      raises the callout/selection UI there THROUGH `user-select: none`, and
      no other engine implements the property at all — Chrome does not even
      report it through `getComputedStyle`, so it cannot be checked in a
      desktop browser and is asserted here instead.

  Both are behind `pointer-coarse` so a mouse keeps ordinary selection: the
  board's title and the roster of who is here are still worth copying.
  """

  use ExUnit.Case, async: true

  @board_live Path.expand("../lib/phoenix_kit_boards/web/board_live.ex", __DIR__)

  defp page_root do
    # The template's outermost element — the one wrapping the header and the
    # canvas together, which is the surface a finger can land on.
    @board_live
    |> File.read!()
    |> String.split("def render(assigns) do")
    |> Enum.at(1)
    |> String.split("<header")
    |> hd()
  end

  describe "the board page refuses selection under a finger" do
    test "a touch drag anywhere on the page selects nothing" do
      assert page_root() =~ "pointer-coarse:select-none",
             "the canvas alone is not enough — the gutter beside it is page, " <>
               "and a drag that starts there takes the whole page with it"
    end

    test "and iOS is told separately, because it needs to be" do
      assert page_root() =~ "pointer-coarse:[-webkit-touch-callout:none]",
             "a long press raises the iOS callout through `user-select: none`"
    end

    test "a mouse is left alone" do
      root = page_root()

      refute root =~ ~r/(?<!pointer-coarse:)\bselect-none\b/,
             "unconditional `select-none` would stop a cursor copying the " <>
               "board's title or a collaborator's name"
    end
  end

  describe "the canvas itself" do
    @fresco Path.expand("../../fresco/priv/static/fresco.js", __DIR__)

    test "still carries the rules it has always carried, plus the callout" do
      # Fresco is a sibling checkout here; skipped where it is a Hex dep, since
      # then it is not this repo's to assert on.
      if File.exists?(@fresco) do
        viewer =
          @fresco
          |> File.read!()
          |> String.split(~s|".fresco-viewer {"|)
          |> Enum.at(1)
          |> String.slice(0, 500)

        assert viewer =~ "touch-action: none"
        assert viewer =~ "user-select: none"

        assert viewer =~ "-webkit-touch-callout: none",
               "the canvas is where a finger rests longest, so it needs the " <>
                 "iOS callout suppressed most of all"
      end
    end
  end
end
