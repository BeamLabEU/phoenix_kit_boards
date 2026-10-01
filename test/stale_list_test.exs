defmodule PhoenixKitBoards.StaleListTest do
  @moduledoc """
  A board edit is sent as the whole board, and that is how work gets lost.

  Reported from a phone: drawing on the phone was replicating to a desktop
  live and well, and then — after letting go and starting something on the
  desktop — "one of the letters I was writing disappeared, I had to redraw
  it".

  Nothing deleted it. Etcher pushes the complete annotation list on every
  change, so a shape's ABSENCE from that list is how a delete is expressed.
  It is also exactly what a list composed a moment before somebody else's
  shape arrived looks like. The phone's socket had stalled; when it came back
  its list went out as it was, without the letter the desktop had drawn in the
  meantime, and `diff/2` read the gap as a deletion and told everybody.

  From the list alone the two are indistinguishable, so they are told apart by
  AGE. A shape this board heard about a second ago cannot have been on the
  sender's screen when they built their payload: their silence is ignorance,
  and the shape is put back before the comparison. One the board has held for
  half a minute, they had and dropped: that is a delete, and it stands.

  The window costs the opposite case — deleting a peer's brand-new shape
  inside it puts the shape back, and you delete it again. Work that cannot be
  recovered is the worse of the two losses. It never touches your own shapes,
  which do not arrive from a peer, so drawing something and undoing it
  straight away is unaffected.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardLive

  defp shape(uuid, kind \\ "marker"), do: %{"uuid" => uuid, "kind" => kind, "geometry" => %{}}

  @now 1_000_000
  @grace BoardLive.peer_grace_ms()

  describe "a list that leaves out a shape the sender never saw" do
    test "does not delete it — it is put back" do
      stored = [shape("a"), shape("b")]
      # "b" arrived from a peer a moment ago; the sender's list predates it.
      arrivals = %{"b" => @now - 200}

      restored = BoardLive.unseen_by_sender(stored, arrivals, [shape("a")], @now)

      assert restored == [shape("b")]

      merged = BoardLive.merge_restored([shape("a")], restored, stored)
      assert merged == stored

      assert BoardLive.empty_delta?(BoardLive.diff(stored, merged)),
             "nothing to tell anyone: the board is as it was"
    end

    test "and without it, the shape is deleted for everybody" do
      # The bug, stated as a test: this is what the board did before.
      stored = [shape("a"), shape("b")]

      assert %{"deleted" => ["b"]} = BoardLive.diff(stored, [shape("a")])
    end

    test "several at once, each back where it was" do
      stored = [shape("a"), shape("b"), shape("c"), shape("d")]
      arrivals = %{"b" => @now - 100, "d" => @now - 100}
      incoming = [shape("a"), shape("c")]

      restored = BoardLive.unseen_by_sender(stored, arrivals, incoming, @now)
      merged = BoardLive.merge_restored(incoming, restored, stored)

      assert merged == stored,
             "position is z-order — putting them on top would restack the board"
    end
  end

  describe "a list that leaves out a shape the sender did see" do
    test "is a delete, and it stands" do
      stored = [shape("a"), shape("b")]
      # Heard about long enough ago that the sender has had it on screen.
      arrivals = %{"b" => @now - @grace - 1}

      assert BoardLive.unseen_by_sender(stored, arrivals, [shape("a")], @now) == []
      assert %{"deleted" => ["b"]} = BoardLive.diff(stored, [shape("a")])
    end

    test "and so is leaving out one of your own" do
      # Your own shapes never arrive from a peer, so nothing protects them:
      # drawing something and undoing it straight away still works.
      stored = [shape("a"), shape("mine")]

      assert BoardLive.unseen_by_sender(stored, %{}, [shape("a")], @now) == []
    end

    test "right up to the edge of the window" do
      stored = [shape("a"), shape("b")]
      incoming = [shape("a")]

      assert BoardLive.unseen_by_sender(stored, %{"b" => @now - @grace}, incoming, @now) == [
               shape("b")
             ]

      assert BoardLive.unseen_by_sender(stored, %{"b" => @now - @grace - 1}, incoming, @now) == []
    end
  end

  describe "what the guard leaves alone" do
    test "an ordinary edit passes through untouched" do
      stored = [shape("a"), shape("b")]
      incoming = [shape("a"), Map.put(shape("b"), "geometry", %{"x" => 1})]

      assert BoardLive.unseen_by_sender(stored, %{"b" => @now}, incoming, @now) == [],
             "the sender mentioned it, so there is nothing to restore"

      assert BoardLive.merge_restored(incoming, [], stored) == incoming
    end

    test "a create is a create, whatever else is in flight" do
      stored = [shape("a")]
      incoming = [shape("a"), shape("new")]

      assert BoardLive.unseen_by_sender(stored, %{}, incoming, @now) == []

      assert %{"created" => [%{"uuid" => "new"}], "deleted" => []} =
               BoardLive.diff(stored, incoming)
    end

    test "an empty board, and an empty list" do
      assert BoardLive.unseen_by_sender([], %{}, [], @now) == []
      assert BoardLive.merge_restored([], [], []) == []

      # Everything cleared, deliberately, by a sender who had it all.
      stored = [shape("a"), shape("b")]
      assert BoardLive.unseen_by_sender(stored, %{}, [], @now) == []
    end

    test "junk in the stored list is not resurrected" do
      stored = [%{"kind" => "marker"}, shape("b")]

      assert BoardLive.unseen_by_sender(stored, %{"b" => @now}, [], @now) == [shape("b")]
    end
  end

  describe "the sender is told what it was missing" do
    @live Path.expand("../lib/phoenix_kit_boards/web/board_live.ex", __DIR__)

    test "directly, because the broadcast deliberately skips them" do
      src = File.read!(@live)

      assert src =~ "defp tell_sender_about_restored(socket, [], _annotations), do: socket"

      assert src =~ ~s|"created" => restored|,
             "their board does not have these shapes — it is why they left " <>
               "them out — so they arrive as new ones"

      assert src =~ "|> tell_sender_about_restored(restored, annotations)"
    end

    test "and the arrivals are forgotten once they have been mentioned" do
      src = File.read!(@live)

      assert src =~ "defp acknowledge_arrivals(socket, incoming) do"

      assert src =~ "|> Map.drop(MapSet.to_list(seen))",
             "a shape the sender has now named is one they can delete"
    end
  end

  describe "the annotations handler, end to end (no DB reached)" do
    defp socket_with(annotations, arrivals) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          annotations: annotations,
          peer_arrivals: arrivals,
          topic: "t",
          board: nil,
          canvas: nil
        }
      }
    end

    defp fresh, do: System.monotonic_time(:millisecond)

    test "a stale list that differs only by the missing shape still tells the sender" do
      stored = [shape("a"), shape("b")]
      socket = socket_with(stored, %{"b" => fresh()})

      {:noreply, socket} =
        BoardLive.handle_event(
          "etcher:annotations-changed",
          %{"annotations" => [shape("a")]},
          socket
        )

      assert [["board:apply", %{"created" => [%{"uuid" => "b"}], "order" => ["a", "b"]}]] =
               socket.private.live_temp.push_events
               |> Enum.map(fn [event, payload] -> [event, payload] end)
    end

    test "restored shapes stay protected, so a second stale list is restored too" do
      stored = [shape("a"), shape("b")]
      socket = socket_with(stored, %{"b" => fresh()})
      params = %{"annotations" => [shape("a")]}

      {:noreply, socket} = BoardLive.handle_event("etcher:annotations-changed", params, socket)
      assert Map.has_key?(socket.assigns.peer_arrivals, "b")

      {:noreply, socket} = BoardLive.handle_event("etcher:annotations-changed", params, socket)
      assert socket.assigns.annotations == stored
    end
  end
end
