using OpenDocumentSpreadsheets
using Test

const SheetCore = OpenDocumentSpreadsheets.SheetCore
const DATA = joinpath(@__DIR__, "data")

# A LibreOffice profile folder as the file URL `-env:UserInstallation` takes: file:///C:/… on
# Windows, file:///tmp/… elsewhere.
lo_profile_url(path) = "file://" * (startswith(path, "/") ? "" : "/") * replace(path, "\\" => "/")

@testset "OpenDocumentSpreadsheets" begin
    @testset "SheetCore" begin
        @testset "references" begin
            include("core/test_references.jl")
        end
        @testset "ranges" begin
            include("core/test_ranges.jl")
        end
        @testset "reference styles" begin
            include("core/test_refstyles.jl")
        end
        @testset "number formats" begin
            include("core/test_numfmt.jl")
        end
        @testset "tables, colours, widths" begin
            include("core/test_misc.jl")
        end
    end
    @testset "container" begin
        include("test_container.jl")
        @testset "namespace prefixes" begin
            include("test_namespaces.jl")
        end
    end
    @testset "read model" begin
        @testset "values" begin
            include("model/test_values.jl")
        end
        @testset "workbook" begin
            include("model/test_workbook.jl")
        end
        @testset "tables" begin
            include("model/test_tables.jl")
        end
        @testset "byte scanner" begin
            include("model/test_sheetscan.jl")
        end
    end
    @testset "formulas" begin
        include("formula/test_openformula.jl")
        include("formula/test_refs.jl")
    end
    @testset "write" begin
        include("write/test_write.jl")
        include("write/test_lines.jl")
        include("write/test_sheetops.jl")
        include("write/test_names.jl")
        include("write/test_sheetprops.jl")
        include("write/test_groups.jl")
        include("write/test_views.jl")
        include("write/test_protection.jl")
        include("write/test_printing.jl")
        include("write/test_docprops.jl")
        include("write/test_extras.jl")
        include("write/test_hyperlinks.jl")
        include("write/test_notes.jl")
        include("write/test_images.jl")
        include("write/test_validation.jl")
        include("write/test_lo_options.jl")
        include("write/test_dbtables.jl")
        include("write/test_autofilter.jl")
    end
    @testset "styles" begin
        include("styles/test_stylesheet.jl")
        include("styles/test_formats.jl")
        include("styles/test_cellformat.jl")
        include("styles/test_numberformat.jl")
        include("styles/test_merge.jl")
        include("styles/test_layout.jl")
        include("styles/test_namedstyles.jl")
    end
    @testset "phase 3 (speed)" begin
        include("test_phase3.jl")
    end
    @testset "public API only" begin
        include("test_public_api.jl")
    end
    @testset "Aqua" begin
        include("test_aqua.jl")
    end
end
