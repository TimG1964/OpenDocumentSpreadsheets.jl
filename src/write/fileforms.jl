# The file forms of the cell-level functions (code review, Phase 5, R6; D-107): every function that takes
# a sheet and a cell or range also takes the file and a sheet-qualified reference (`"Sheet1.A1"`,
# `"Sheet1!A1:B2"`), as the formatting functions do.

# A sheet-qualified reference as its sheet and the cell or range on it.
function _on_sheet(xf::ODSFile, ref::AbstractString)
    r = try
        parse_sheet_ref(String(ref))
    catch e
        e isa ODSError || rethrow()
        nothing
    end
    r isa SheetCellRef && return getsheet(xf, r.sheet), r.cellref
    r isa SheetCellRange && return getsheet(xf, r.sheet), r.rng
    throw(ODSError("`$ref` is not a cell or range with its sheet (`\"Sheet1.A1\"`, `\"Sheet1.A1:B2\"`)."))
end

for f in (:addComment, :deleteComment, :getComment, :addThreadedComment, :addThreadedReply, :deleteThreadedComment,
          :getThreadedComment, :setThreadedCommentResolved, :addHyperlink, :deleteHyperlink, :getHyperlink, :addImage,
          :deleteImage, :getDataValidation, :setFormula, :setColoredDataBars)
    @eval begin
        """
            $($(string(f)))(xf::ODSFile, "Sheet1.A1", args...; kw...)

        The same, on a cell or range given with its sheet.
        """
        function $f(xf::ODSFile, ref::AbstractString, args...; kw...)
            ws, r = _on_sheet(xf, ref)
            return $f(ws, r, args...; kw...)
        end
    end
end
