defmodule PhoenixKitBoards.Web.Components do
  @moduledoc """
  Function components to drop into a host app's pages.

      <PhoenixKitBoards.Web.Components.boards_panel
        id="project-notes"
        scope={{"project", @project.uuid}}
        label="Notes"
        current_user={@current_scope.user}
      />

  See `PhoenixKitBoards.Web.BoardsPanel` for every attribute.
  """
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:current_user, :any, required: true)
  attr(:scope, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:show_label, :boolean, default: true)
  attr(:folder, :any, default: nil)
  attr(:visibility_options, :list, default: [:private, :shared])
  attr(:default_visibility, :atom, default: :shared)
  attr(:actions, :list, default: [:empty, :text, :image])
  attr(:limit, :integer, default: 11)
  attr(:open, :atom, default: :navigate, values: [:navigate, :new_tab])
  attr(:return_to, :string, default: nil)
  attr(:poll, :integer, default: 5_000)
  attr(:class, :string, default: nil)

  @doc "A widget for the quick boards of one place. See the module doc."
  def boards_panel(assigns) do
    ~H"""
    <.live_component module={PhoenixKitBoards.Web.BoardsPanel} {assigns} />
    """
  end
end
