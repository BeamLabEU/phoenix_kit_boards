defmodule PhoenixKitBoards.BoardUploadTest do
  @moduledoc """
  Pins the two things `store/4` must not get wrong again: the file type and
  the checksum algorithm.

  `@image_accept` invites audio and video onto the board. Hardcoding
  `file_type: "image"` stored every one of them as an image — broken
  thumbnails, invisible to the media-page filters, image variant processing
  run against a `.mov`. Classified through core's one `determine_file_type/2`.

  The checksum has to be SHA256. Core's media browser hashes with
  `Auth.calculate_file_hash/1` (SHA256) and `store_file_in_buckets/6` dedupes
  on that value, so an MD5 here meant the same bytes pasted onto a board and
  later uploaded through the media page minted two rows.

  The suite has no database, so this exercises the helpers the LiveView
  exposes as `@doc false` — the same pattern as `decode_data_url/1`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBoards.Web.BoardLive

  describe "file_type_for/1" do
    test "images stay images" do
      assert BoardLive.file_type_for(%{client_type: "image/png", client_name: "shot.png"}) ==
               "image"

      assert BoardLive.file_type_for(%{client_type: "image/jpeg", client_name: "shot.jpg"}) ==
               "image"

      assert BoardLive.file_type_for(%{client_type: "image/webp", client_name: "shot.webp"}) ==
               "image"
    end

    test "audio is not stored as an image" do
      assert BoardLive.file_type_for(%{client_type: "audio/mpeg", client_name: "song.mp3"}) ==
               "audio"

      assert BoardLive.file_type_for(%{client_type: "audio/mp4", client_name: "song.m4a"}) ==
               "audio"

      assert BoardLive.file_type_for(%{client_type: "audio/ogg", client_name: "song.ogg"}) ==
               "audio"

      assert BoardLive.file_type_for(%{client_type: "audio/wav", client_name: "song.wav"}) ==
               "audio"

      assert BoardLive.file_type_for(%{client_type: "audio/opus", client_name: "song.opus"}) ==
               "audio"
    end

    test "video is not stored as an image" do
      assert BoardLive.file_type_for(%{client_type: "video/mp4", client_name: "clip.mp4"}) ==
               "video"

      assert BoardLive.file_type_for(%{client_type: "video/webm", client_name: "clip.webm"}) ==
               "video"

      assert BoardLive.file_type_for(%{client_type: "video/quicktime", client_name: "clip.mov"}) ==
               "video"
    end

    test "filename wins when the browser sends a generic type" do
      # `.m4a` is in core's audio-extension fallback; `MIME.from_path/1` does
      # not know it. `.mov` it does.
      assert BoardLive.file_type_for(%{
               client_type: "application/octet-stream",
               client_name: "song.m4a"
             }) == "audio"

      assert BoardLive.file_type_for(%{
               client_type: "application/octet-stream",
               client_name: "clip.mov"
             }) == "video"
    end
  end

  describe "file_checksum/1" do
    @tag :tmp_dir
    test "matches the media library's SHA256 hasher", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "paste.bin")
      File.write!(path, "hello boards")

      expected = Auth.calculate_file_hash(path)
      md5 = :md5 |> :crypto.hash("hello boards") |> Base.encode16(case: :lower)

      assert {:ok, ^expected} = BoardLive.file_checksum(path)
      refute expected == md5
    end

    test "a missing file is an error, not a raise" do
      assert {:error, :enoent} = BoardLive.file_checksum("/no/such/board-upload")
    end
  end
end
