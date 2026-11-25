# A precompile workload, mirroring XLSX.jl's (its src/XLSX.jl).
#
# Writes one small spreadsheet holding each common cell type, then reads it back through
# every read path. Compile cost grows with the number of distinct methods and types run,
# not with the number of cells, so the data stays tiny. Paths are exercised with a file
# name (`String`) as well as an `IOBuffer`: the entry points specialize on each. Niche
# features are left out: they cost precompile time paid by every user (D-044, D-065); a feature
# whose first call passes 0.5 s comes in (D-080).
# Users can turn this off with the PrecompileTools preference `precompile_workload = false`.
PCT.@setup_workload begin
    let
        dir = mktempdir()
        path = joinpath(dir, "precompile.ods")
        io = IOBuffer()
        nt = (i = [1, 2, 3], f = [1.5, 2.5, 3.5], s = ["a", "b", "c"], b = [true, false, true],
              d = [Dates.Date(2024, 1, 1), Dates.Date(2024, 1, 2), Dates.Date(2024, 1, 3)],
              dt = [Dates.DateTime(2024, 1, 1, 12), Dates.DateTime(2024, 1, 2, 12), Dates.DateTime(2024, 1, 3, 12)],
              m = Union{Missing,Int}[1, missing, 3])
        try
            PCT.@compile_workload begin
                # Writing
                writetable(path, nt; overwrite = true)
                writetable(path, "A" => nt, "B" => nt; overwrite = true)
                xf = openods(path; mode = "rw")
                sh = xf["A"]
                # Cell assignment compiles once per value type and reference form.
                vals = Any[1, 2.5, "x", true, Dates.Date(2024, 1, 1), Dates.DateTime(2024, 1, 1, 12), missing]
                for (c, v) in enumerate(vals)
                    sh[string("J", c)] = v
                    sh[CellRef(2, 9 + c)] = v
                    sh[3, 9 + c] = v
                end
                sh[5, :] = vals    # as XLSX.jl's workload

                sh["J6:K7"] = "y"
                setFormula(sh, "L1"; val = "=SUM(A2:A4)")
                writetable!(addsheet!(xf, "C"), Any[nt.i, nt.s], [:i, :s])
                setFont(sh, "A1"; bold = true, color = "red")
                setFill(sh, "A2"; pattern = "solid", fgColor = "yellow")
                setAlignment(sh, "A3"; horizontal = "center", wrapText = true)
                setFormat(sh, "B2"; format = "0.00")
                setBorder(sh, "A1:C3"; allsides = ["style" => "thin", "color" => "black"])
                setBorder(sh, "A1:C3"; outside = ["style" => "thick"])
                setUniformFont(sh, "A2:C3"; italic = true)
                setUniformFill(sh, "A2:C3"; pattern = "solid", fgColor = "yellow")
                setUniformAlignment(sh, "A2:C3"; horizontal = "center")
                setUniformFormat(sh, "B2:B3"; format = "0.00")
                setUniformBorder(sh, "A2:C3"; bottom = ["style" => "thin"])
                setColumnWidth(sh, 1; width = 12)
                mergeCells(sh, "J6:K7")
                addCellStyle!(xf, "Total"; font = (bold = true,), fill = (pattern = "solid", fgColor = "yellow"))
                setCellStyle(sh, "A4", "Total")       # OpenDocumentSpreadsheets only: named styles (D-045)
                setCellStyle(sh, "B4", "Heading 1")
                saveods(xf)
                writeods(io, xf)
                xf = newods()
                xf[1]["A1:B2"] = 1.5
                writeods(IOBuffer(), xf)
                streamods(IOBuffer()) do s
                    ss = addsheet!(s, "S"; columns = ["n", "x"])
                    writerow!(ss, (1, 2.5))
                end

                # Reading
                dt = readtable(path, 1)
                Tables.columns(dt)
                Tables.schema(dt)
                readtable(path, "A", "A:C")
                readtable(seekstart(io), 1)
                xf = readods(path)
                sheetnames(xf)
                sh = xf["A"]
                sh["A1:C4"]
                getdata(sh)
                sh[2, 1]
                getcell(sh, "B2")
                getFormula(sh, "L1")
                openods(path) do xf
                    gettable(xf[1])
                    for r in eachtablerow(xf[1])
                        r[1]
                    end
                end
                openods(path; enable_cache = false) do xf
                    for r in eachrow(xf[1])
                        r[1]
                    end
                end
                readdata(path, 1, "A1:C3")
                readdata(path, "A.A1:B2")

                # Links, notes, validation, filters and sorts (D-080): their first calls took 1.8 s a
                # session (setAutoFilter 0.65 s, addComment 0.55 s), for 5 s more precompilation
                xf = openods(path; mode = "rw")
                sh = xf["A"]
                addHyperlink(sh, "C2"; url = "https://example.org/")
                addComment(sh, "C3", "note"; author = "A")
                addDataValidation(sh, "A2:A4"; type = :whole, operator = :between, formula1 = 1, formula2 = 9)
                setAutoFilter(sh, "A1:G4"; filters = ["i" => (">" => 1), "s" => ["a", "b"]], sort = "f" => :descending)
                writeods(IOBuffer(), xf)
                xf = readods(seekstart(io))
                getHyperlinks(xf["A"]); getComments(xf["A"]); getDataValidations(xf["A"]); getAutoFilter(xf["A"])

                # Conditional formats (D-083): a rule with a format of its own, the kinds without, and
                # the bands; their first calls took 2.6 s a session
                xf = openods(path; mode = "rw")
                sh = xf["A"]
                setConditionalFormat(sh, "A2:A4", :cellIs; operator = "greaterThan", value = "1", dxStyle = "greenfilltext")
                setConditionalFormat(sh, "A2:A4", :expression; formula = "A2>B2", font = ["bold" => "true"])
                setConditionalFormat(sh, "B2:B4", :dataBar)
                setConditionalFormat(sh, "B2:B4", :colorScale; colorscale = "greenyellow")
                setConditionalFormat(sh, "B2:B4", :iconSet)
                setColoredDataBars(sh, "A2:A4"; bands = 2)
                getConditionalFormats(sh); clearConditionalFormats(sh, "B:B")
                writeods(IOBuffer(), xf)
            end
        finally
            rm(dir; recursive = true, force = true)
        end
    end
end
