defmodule PhoenixKitBoards.EmbeddedImageTest do
  @moduledoc """
  An image whose upload failed is embedded in the shape as a base64 `data:`
  URL so the paste survives. The client re-sends every shape on every edit, so
  those bytes then go up the socket again each time anyone nudges anything —
  a real board carried four of them, 5.34 MB of the 5.36 MB it sent per edit,
  against 23 KB of actual drawing. Reading them back out is what makes an edit
  small enough to feel live.

  Covers the reading; storing them is integration, and this suite has no
  database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardLive

  # 1x1 transparent PNG.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

  describe "reading an embedded image" do
    test "decodes the bytes and names the format" do
      assert {:ok, bytes, "png"} = BoardLive.decode_data_url("data:image/png;base64," <> @png)
      # Really the PNG, not just something that survived base64.
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> = bytes
    end

    test "jpeg is stored as .jpg, not .jpeg" do
      assert {:ok, _, "jpg"} = BoardLive.decode_data_url("data:image/jpeg;base64,/9j/4AAQ")
    end

    test "keeps the format for types with no special case" do
      assert {:ok, _, "webp"} = BoardLive.decode_data_url("data:image/webp;base64," <> @png)
      assert {:ok, _, "gif"} = BoardLive.decode_data_url("data:image/gif;base64," <> @png)
    end

    test "svg keeps a usable extension rather than the whole subtype" do
      assert {:ok, _, "svg"} = BoardLive.decode_data_url("data:image/svg+xml;base64," <> @png)
    end

    test "reads a URL carrying extra parameters" do
      assert {:ok, _, "png"} =
               BoardLive.decode_data_url("data:image/png;charset=utf-8;base64," <> @png)
    end

    test "tolerates base64 broken across lines" do
      wrapped =
        @png |> String.graphemes() |> Enum.chunk_every(40) |> Enum.map_join("\n", &Enum.join/1)

      assert {:ok, bytes, "png"} = BoardLive.decode_data_url("data:image/png;base64," <> wrapped)
      assert byte_size(bytes) > 0
    end

    test "an unknown media type still yields a usable extension" do
      assert {:ok, _, "png"} = BoardLive.decode_data_url("data:;base64," <> @png)
    end
  end

  describe "what is left alone" do
    # These must report an error rather than raise: the caller keeps the shape
    # as it is and the board carries on, which is where it already was. A raise
    # would take the edit — and the board — down with it.
    test "a stored URL is not a data URL" do
      assert {:error, :not_a_data_url} = BoardLive.decode_data_url("/phoenix_kit/files/abc")
      assert {:error, :not_a_data_url} = BoardLive.decode_data_url("https://example.com/a.png")
    end

    test "a percent-encoded data URL is declined rather than guessed at" do
      assert {:error, :not_base64} =
               BoardLive.decode_data_url("data:image/svg+xml,%3Csvg%2F%3E")
    end

    test "base64 that isn't" do
      assert {:error, :bad_base64} = BoardLive.decode_data_url("data:image/png;base64,!!!!")
    end

    test "no comma at all" do
      assert {:error, :malformed_data_url} = BoardLive.decode_data_url("data:image/png;base64")
    end

    test "nothing useful" do
      assert {:error, _} = BoardLive.decode_data_url("data:")
      assert {:error, _} = BoardLive.decode_data_url("")
    end
  end
end
