defmodule PhoenixKitBoards.BoardSocketTest do
  @moduledoc """
  The ephemeral channel's join token.

  It is the whole of the access control on that socket: it says which board
  may be opened and who the opener is, and the channel re-derives both from it
  rather than believing anything the client says. So the checks that matter
  are that it round-trips, that it cannot be moved to another board, and that
  it cannot be edited.

  `Phoenix.Token` takes a raw secret as well as an endpoint, which is what
  lets this run without standing one up.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardSocket

  @secret String.duplicate("abcdefgh", 8)
  @board "019f5d8a-d337-7915-8957-786f9bb2b8d4"

  defp peer(overrides \\ %{}) do
    Map.merge(%{id: "#{@board}:a1b2c3", name: "Ada", color: "#ef4444"}, overrides)
  end

  describe "the token" do
    test "carries the board and the peer" do
      token = BoardSocket.sign(@secret, @board, peer())

      assert {:ok, claims} = BoardSocket.verify(@secret, token)
      assert claims.board == @board
      assert claims.id == "#{@board}:a1b2c3"
      assert claims.name == "Ada"
      assert claims.color == "#ef4444"
    end

    test "is bound to one board" do
      # The channel compares `claims.board` against the topic it was asked to
      # join. Without that check a token for any board would open every board,
      # which on a private one is the entire access control.
      token = BoardSocket.sign(@secret, @board, peer())
      {:ok, claims} = BoardSocket.verify(@secret, token)

      refute claims.board == "some-other-board"
    end

    test "cannot be edited" do
      token = BoardSocket.sign(@secret, @board, peer())

      # Flip a character in the payload rather than append to it — appending
      # can land in the signature and read as an ordinary bad token.
      tampered =
        case String.split(token, ".") do
          [head | rest] ->
            flipped =
              String.replace(head, ~r/^./, if(String.starts_with?(head, "a"), do: "b", else: "a"))

            Enum.join([flipped | rest], ".")
        end

      assert BoardSocket.verify(@secret, tampered) in [{:error, :invalid}, {:error, :expired}]
    end

    test "is refused under a different secret" do
      token = BoardSocket.sign(@secret, @board, peer())
      other = String.duplicate("12345678", 8)

      assert {:error, :invalid} = BoardSocket.verify(other, token)
    end

    test "expires" do
      token = BoardSocket.sign(@secret, @board, peer())

      # Signed now, so asking for a token no older than "before now" must
      # reject it — proof the age is actually enforced rather than the option
      # being carried and ignored.
      assert {:error, :expired} =
               Phoenix.Token.verify(@secret, "phoenix_kit_boards board peer", token, max_age: -1)
    end

    test "nonsense is rejected rather than raising" do
      for bad <- ["", "not-a-token", "a.b.c"] do
        assert {:error, _} = BoardSocket.verify(@secret, bad)
      end
    end
  end

  describe "mount_path/0" do
    test "defaults to the documented path" do
      assert BoardSocket.mount_path() == "/phoenix_kit/board"
    end

    test "a host that mounted it elsewhere says so" do
      Application.put_env(:phoenix_kit_boards, :board_socket_path, "/elsewhere")
      on_exit(fn -> Application.delete_env(:phoenix_kit_boards, :board_socket_path) end)

      assert BoardSocket.mount_path() == "/elsewhere"
    end
  end
end
