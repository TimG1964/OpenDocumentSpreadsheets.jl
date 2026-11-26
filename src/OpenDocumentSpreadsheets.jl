"""
    OpenDocumentSpreadsheets

Read and write OpenDocument spreadsheets (`.ods`, `.fods`, `.ots`) in pure Julia.

The manual is at <https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev/>.
"""
module OpenDocumentSpreadsheets

import Dates
import Parsers
import PrecompileTools as PCT
import Tables
import Unicode
import XML
import ZipArchives
using Printf: @printf, @sprintf
using SHA: sha1                       # protection keys (phase 5 step 9)
using Base64: base64encode

# The format-independent core, shared in future with XLSX.jl (D-001). OpenDocumentSpreadsheets uses it by
# qualified name (`SheetCore.CellRef`), or through the names imported below.
include("core/SheetCore.jl")
using .SheetCore: SheetCoreError, readentry_string, readentry_prefix, CellRef, CellRange, ColumnRange, RowRange,
    row_number, column_number, is_valid_cellname, is_valid_cellrange, is_valid_column_range,
    is_valid_row_range, DataTable, TableRow, TableRowIterator
# functions the back end adds methods to
import .SheetCore: getdata, gettable, eachtablerow

# Sheet-qualified references in OpenDocumentSpreadsheets are always in LibreOffice's notation (D-015):
# they print as `Sheet1.A1`, and parse that form as well as Excel's `Sheet1!A1`.
const SheetCellRef       = SheetCore.SheetCellRef{SheetCore.ODFStyle}
const SheetCellRange     = SheetCore.SheetCellRange{SheetCore.ODFStyle}
const SheetColumnRange   = SheetCore.SheetColumnRange{SheetCore.ODFStyle}
const SheetRowRange      = SheetCore.SheetRowRange{SheetCore.ODFStyle}
const NonContiguousRange = SheetCore.NonContiguousRange{SheetCore.ODFStyle}
parse_sheet_ref(s::AbstractString) = SheetCore.parse_sheet_ref(SheetCore.ODFStyle, s)

"""
    ODSError

The exception OpenDocumentSpreadsheets throws for its own errors: an invalid reference, a missing sheet, a
file that is not an ODF spreadsheet, and so on. It is the shared core's `SheetCoreError`,
so one type covers errors from both.
"""
const ODSError = SheetCoreError

# container I/O (phase 0)
include("io/namespaces.jl")
include("io/container.jl")
include("io/sheetindex.jl")
include("io/prefix.jl")
include("io/writer.jl")

# the read model (phase 1); full cell styles (phase 4)
include("styles/cellstyle.jl")
include("model/styleindex.jl")
include("model/cells.jl")
include("model/sheetreader.jl")
include("model/sheetscan.jl")
include("styles/formats.jl")
include("model/indexmap.jl")
include("model/workbook.jl")
include("model/access.jl")
include("model/rows.jl")
include("model/tables.jl")
include("model/richtext.jl")
include("formula/openformula.jl")
include("formula/uiformula.jl")
include("formula/refs.jl")

# the write path (phase 2)
include("write/values.jl")
include("styles/stylesheet.jl")
include("styles/sheetformats.jl")
include("write/edit.jl")
include("styles/targets.jl")
include("styles/cellformat.jl")
include("styles/numberstyle.jl")
include("styles/format.jl")
include("styles/merge.jl")
include("styles/layout.jl")
include("styles/named.jl")
include("write/lines.jl")
include("write/xmlout.jl")
include("write/rewrite.jl")
include("write/cellextras.jl")
include("write/objects.jl")
include("write/patch.jl")
include("write/patchmap.jl")
include("write/settings.jl")
include("write/sheetops.jl")
include("write/names.jl")
include("write/sheetprops.jl")
include("write/groups.jl")
include("write/views.jl")
include("write/protection.jl")
include("write/printing.jl")
include("write/docprops.jl")
include("write/hyperlinks.jl")
include("write/richtext.jl")
include("write/notes.jl")
include("write/images.jl")
include("write/validation.jl")
include("write/dbtables.jl")
include("write/conditional.jl")
include("write/sparklines.jl")
include("write/cfrules.jl")
include("write/collate.jl")
include("write/autofilter.jl")
include("write/sort.jl")
include("write/save.jl")
include("write/stream.jl")
include("write/writetable.jl")

# Charts (phase 8): a submodule, as in XLSX.jl, with the same few names bound here
include("charts/Charts.jl")
using .Charts: Charts, AbstractChart, Chart, ChartEx, ChartRef, ChartSeries, getChartSchema, getChartType, getCharts,
    getChart, getChartData, getChartRanges, addSparklines, getSparklines, deleteSparklines

export
    # files and worksheets
    ODSFile, readods, openods, newods, writeods, saveods,
    Worksheet, sheetnames, sheetcount, hassheet, addsheet!,
    # cells and data
    CellRef, SheetCellRef, row_number, column_number, eachtablerow,
    readdata, getdata, gettable, readtable, readto,
    iserror, geterror,
    setdata!, setFormula,
    writetable, writetable!, streamods, writerow!, writerows!,
    # formats
    setFont, setBorder, setFill, setAlignment,
    RichTextString, RichTextRun,                # rich text (D-088), as XLSX.jl exports them
    setFormat, setUniformFormat,
    setUniformFont, setUniformBorder, setUniformFill, setUniformAlignment, setUniformStyle,
    getMergedCells, isMergedCell, getMergedBaseCell, mergeCells, removeMergedCells,
    setColumnWidth, setRowHeight, autofitColumns,
    setCellStyle, addCellStyle!,
    # sheets
    insertRows, insertColumns, deleteRows, deleteColumns,
    renamesheet!, deletesheet!, copysheet!, movesheet!,
    addDefinedName, deleteDefinedName, deleteAllDefinedNames,
    setRowHidden, setColumnHidden, setSheetVisibility, setTabColor, removeTabColor,
    groupRows, groupColumns, ungroupRows, ungroupColumns,
    freezePanes, splitFreeze, splitPanes, removePanes, setSheetView,
    protectSheet, unprotectSheet, setCellProtection, protectWorkbook, unprotectWorkbook,
    setPageSetup, setPageMargins, setPrintOptions, setPrintArea, removePrintArea, setPrintTitles, removePrintTitles,
    setHeaderFooter, removeHeaderFooter, headerFooterField, headerFooterFont,
    setDocumentProperties, setCustomProperty, deleteCustomProperty,
    # rich objects
    addHyperlink, deleteHyperlink,
    addComment, deleteComment,
    addThreadedComment, addThreadedReply, setThreadedCommentResolved, deleteThreadedComment,
    addImage, deleteImage,
    addDataValidation, deleteDataValidation,
    addtable!, deletetable!, settotals!, gettotals, removetotals!, appendtable!, gettablerange,
    setAutoFilter, removeAutoFilter,
    setConditionalFormat,
    # sparklines
    addSparklines, getSparklines, deleteSparklines

@static if VERSION >= v"1.11"
    eval(Meta.parse("public getcell, getcellrange, getFormula, getRichTextString, get_dimension, ODSError, Cell, EmptyCell, DataTable, TableRow, TableRowIterator, SheetRow, StreamWriter, StreamSheet, " *
                    "getFont, getBorder, getFill, getAlignment, getFormat, getText, getDefaultFont, setOutsideBorder, CellFont, CellFill, CellBorder, CellAlignment, CellFormat, getColumnWidth, getRowHeight, getCellStyle, " *
                    "getDefinedNames, getAllDefinedNames, DefinedName, isRowHidden, isColumnHidden, getSheetVisibility, getTabColor, getRowOutlineLevel, getColumnOutlineLevel, getSheetView, " *
                    "isSheetProtected, getSheetProtection, getCellProtection, isWorkbookProtected, getWorkbookProtection, " *
                    "getPageSetup, getPageMargins, getPrintOptions, getPrintArea, getPrintTitles, getHeaderFooter, " *
                    "getDocumentProperties, getCustomProperty, getCustomProperties, " *
                    "getHyperlink, getHyperlinks, getComment, getComments, getThreadedComment, getThreadedComments, getImages, getDataValidation, getDataValidations, " *
                    "Table, TableStyleInfo, table, tables, getAutoFilter, getConditionalFormats, clearConditionalFormats, setColoredDataBars, " *
                    "Charts, AbstractChart, Chart, ChartEx, ChartRef, ChartSeries, getChartSchema, getChartType, getCharts, getChart, getChartData, getChartRanges"))
end

include("precompile.jl")

end # module
