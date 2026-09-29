defmodule PhoenixKitBoards.LiveDrawingRelayTest do
  @moduledoc """
  What the board relays while somebody is still drawing.

  A shape is stored when it is finished, which left everyone else watching
  nothing happen for the length of a stroke and then a finished stroke
  appearing. The drag had already been solved this way (`"moving"`); drawing
  is the same idea one step earlier, and one step harder: the shape has no
  uuid yet, so the draft itself travels and the sender's id is the key peers
  file it under. One person draws one shape at a time.

  The draft arrives from a browser and goes further into the page than most
  of what this channel carries: `kind` chooses the SVG element a peer's
  canvas builds for it. So it is checked here, and this pins what it refuses.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardChannel

  describe "a draft on its way to the other people on the board" do
    test "a stroke travels whole: kind, geometry and the style being drawn" do
      draft = %{
        "kind" => "marker",
        "geometry" => %{"points" => [[10.5, 20.25], [12.0, 24.5]]},
        "style" => %{"color" => "#ef4444", "width" => 4}
      }

      assert BoardChannel.sanitize_draft(draft) == draft
    end

    test "style is optional — a shape drawn with the defaults carries none" do
      draft = %{"kind" => "rectangle", "geometry" => %{"x" => 0, "y" => 0, "w" => 4, "h" => 4}}

      assert BoardChannel.sanitize_draft(draft) == draft
      refute Map.has_key?(BoardChannel.sanitize_draft(draft), "style")
    end

    test "a style that is not a map is dropped rather than relayed" do
      draft = %{"kind" => "marker", "geometry" => %{"points" => []}, "style" => "red"}

      assert BoardChannel.sanitize_draft(draft) == %{
               "kind" => "marker",
               "geometry" => %{"points" => []}
             }
    end
  end

  describe "and what it will not carry" do
    test "a kind that is not shaped like a kind" do
      # It picks an element to build, so it is held to the same shape as a
      # tool name: lowercase, short, no punctuation to smuggle anything in.
      for kind <- [
            "<script>",
            "Marker",
            "marker; drop",
            "../../etc",
            String.duplicate("m", 40),
            "",
            123,
            nil
          ] do
        assert BoardChannel.sanitize_draft(%{"kind" => kind, "geometry" => %{}}) == nil,
               "#{inspect(kind)} should not reach a peer's canvas"
      end
    end

    test "geometry that is not a map" do
      for geometry <- [nil, "points", [[1, 2]], 7] do
        assert BoardChannel.sanitize_draft(%{"kind" => "marker", "geometry" => geometry}) == nil
      end
    end

    test "a draft missing its halves entirely" do
      assert BoardChannel.sanitize_draft(%{}) == nil
      assert BoardChannel.sanitize_draft(%{"kind" => "marker"}) == nil
      assert BoardChannel.sanitize_draft(%{"geometry" => %{}}) == nil
      assert BoardChannel.sanitize_draft(nil) == nil
      assert BoardChannel.sanitize_draft("marker") == nil
    end
  end

  describe "the relay is wired at both ends" do
    @channel Path.expand("../lib/phoenix_kit_boards/web/board_channel.ex", __DIR__)
    @hook Path.expand("../priv/static/assets/phoenix_kit_boards.js", __DIR__)

    test "the channel relays the frames and the end, and excludes the sender" do
      src = File.read!(@channel)

      assert src =~ ~s|def handle_in("drawing"|
      assert src =~ ~s|def handle_in("drawn"|

      # `broadcast_from`, not `broadcast`: the sender drew it locally, and an
      # echo would fight the stroke still in progress.
      [_, drawing] = String.split(src, ~s|def handle_in("drawing"|, parts: 2)
      [drawing, _] = String.split(drawing, "\n  end", parts: 2)

      assert drawing =~ "broadcast_from("
      assert drawing =~ ~s|"drawing",|
      refute drawing =~ ~s|broadcast(socket|

      assert src =~ ~s|broadcast_from(socket, "drawn"|

      assert src =~ ~s|"id" => socket.assigns.peer.id|,
             "the sender's id is the key a peer files the draft under"
    end

    test "each frame says which stroke it belongs to" do
      # So a peer can recognise a frame from a stroke that is already over —
      # one that crossed the end on the wire, or that a reconnect flushed out
      # of a queue — instead of replaying a drawing nobody is making any more.
      src = File.read!(@channel)

      # Both of them: a stroke whose frames are numbered and whose end is not
      # can never be recognised as finished, which is the whole point.
      for event <- ["drawing", "drawn"] do
        [_, body] = String.split(src, ~s|def handle_in("#{event}"|, parts: 2)
        [body, _] = String.split(body, "\n  end", parts: 2)

        assert body =~ ~s|"stroke" => stroke_no(params)|,
               ~s|"#{event}" must say which stroke it belongs to|
      end

      assert src =~ "defp stroke_no(%{\"stroke\" => n}) when is_integer(n) and n >= 0, do: n"

      assert src =~ "defp stroke_no(_params), do: nil",
             "a client that does not number its strokes is simply unknown, " <>
               "which is what every client was before this existed"
    end

    test "an ephemeral frame is dropped rather than queued when the line is down" do
      # Phoenix buffers a push made on a channel that is down and flushes the
      # lot on rejoin. Right for an edit; wrong for everything on this
      # channel, all of which is a picture of this instant.
      src = File.read!(@hook)

      [_, push] = String.split(src, "    push(id, event, payload) {", parts: 2)
      [push, _] = String.split(push, "\n    },", parts: 2)

      assert push =~ "if (!link.joined) return false;"
      assert push =~ "!link.socket.isConnected()) return false;"
    end

    test "and a frame from a finished stroke is ignored on arrival" do
      src = File.read!(@hook)

      assert src =~ "if (this.strokeIsOver(id, stroke)) return;"
      assert src =~ "this.noteStrokeOver(id, stroke);"
      assert src =~ ~s|BoardLink.push(this.frescoId, "drawing", { draft, stroke: this.strokeNo })|

      assert src =~ "this.strokeNo += 1;",
             "the next stroke is a new one, or its frames would be taken for " <>
               "the last one's and thrown away"
    end

    test "the browser both sends its own and shows everyone else's" do
      src = File.read!(@hook)

      assert src =~ "layer.onDrawing(", "our own stroke is reported"
      assert src =~ ~s|BoardLink.push(this.frescoId, "drawing"|
      assert src =~ ~s|BoardLink.push(this.frescoId, "drawn"|

      assert src =~ ~s|BoardLink.on(this.frescoId, "drawing"|, "a peer's stroke is shown"
      assert src =~ "layer.applyDrawing(id, draft)"

      assert src =~ ~s|BoardLink.on(this.frescoId, "drawn"|,
             "…and taken away when they let go, so an abandoned stroke leaves nothing"

      assert src =~ "layer.applyDrawingEnd(id)"
    end
  end
end
