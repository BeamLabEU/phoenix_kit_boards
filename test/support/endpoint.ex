defmodule PhoenixKitBoards.Test.Endpoint do
  @moduledoc "A bare endpoint so `Phoenix.LiveViewTest` can mount LiveViews."
  use Phoenix.Endpoint, otp_app: :phoenix_kit_boards

  @session_options [store: :cookie, key: "_boards_test", signing_salt: "boards-test-salt"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
end
