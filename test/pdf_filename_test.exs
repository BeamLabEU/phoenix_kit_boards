defmodule PhoenixKitBoards.PdfFilenameTest do
  @moduledoc """
  The download name for "Export as PDF" from a tile. Fresco uses the name it
  is given as-is, so this is what strips characters a filesystem refuses and
  adds `.pdf`. The hook in `boards_panel_export.js` does the same cleaning;
  `test/js/panel_export_test.js` lists the same inputs.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.BoardsPanel

  test "download names" do
    assert BoardsPanel.pdf_filename("Q3 plan") == "Q3 plan.pdf"
    assert BoardsPanel.pdf_filename("Q3 plan.pdf") == "Q3 plan.pdf"
    assert BoardsPanel.pdf_filename("notes.PDF") == "notes.pdf"
    assert BoardsPanel.pdf_filename("Q3: plan") == "Q3_ plan.pdf"
    assert BoardsPanel.pdf_filename("a/b\\c*d?e\"f<g>h|i") == "a_b_c_d_e_f_g_h_i.pdf"
    assert BoardsPanel.pdf_filename("Q3:\nplan") == "Q3_plan.pdf"
    assert BoardsPanel.pdf_filename("   ") == "board.pdf"
    assert BoardsPanel.pdf_filename("...") == "board.pdf"
    assert BoardsPanel.pdf_filename("...hidden") == "hidden.pdf"
    assert BoardsPanel.pdf_filename(".pdf") == "board.pdf"
  end
end
