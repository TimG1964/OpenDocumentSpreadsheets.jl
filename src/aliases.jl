# XLSX.jl's names that this package's consistency rules renamed (code review, Phase 5): kept as aliases,
# `public` but not exported, so code written for XLSX.jl still runs. Each is the same function as its
# new name. The guide's *Coming from XLSX.jl* page and records/api-divergence.md list them.

# D-104 (R2): one verb, `delete`, for every removal (XLSX.jl's `remove…` and `clear…`)

"""
    removeAutoFilter(sheet)

Another name for [`deleteAutoFilter`](@ref): the same function.
"""
const removeAutoFilter = deleteAutoFilter

"""
    removeHeaderFooter(sheet)

Another name for [`deleteHeaderFooter`](@ref): the same function.
"""
const removeHeaderFooter = deleteHeaderFooter

"""
    removeMergedCells(sheet, ref)

Another name for [`deleteMergedCells`](@ref): the same function.
"""
const removeMergedCells = deleteMergedCells

"""
    removePanes(sheet)

Another name for [`deletePanes`](@ref): the same function.
"""
const removePanes = deletePanes

"""
    removePrintArea(sheet)

Another name for [`deletePrintArea`](@ref): the same function.
"""
const removePrintArea = deletePrintArea

"""
    removePrintTitles(sheet)

Another name for [`deletePrintTitles`](@ref): the same function.
"""
const removePrintTitles = deletePrintTitles

"""
    removeTabColor(sheet)

Another name for [`deleteTabColor`](@ref): the same function.
"""
const removeTabColor = deleteTabColor

"""
    removetotals!(sheet, name) / removetotals!(table)

Another name for [`deletetotals!`](@ref): the same function.
"""
const removetotals! = deletetotals!

"""
    clearConditionalFormats(sheet, ref)

Another name for [`deleteConditionalFormats`](@ref): the same function.
"""
const clearConditionalFormats = deleteConditionalFormats
