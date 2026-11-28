# Font, fill, border and alignment (phase 4, step 4).
#
# The first test sets are ported from XLSX.jl 0.13.4 (test/test_files/formatting/styles.jl:
# "setFont", "setBorder", "setFill", "setAlignment", "UniformStyle"), MIT License, Copyright
# (c) 2018-2026 Felipe Noronha Tavares and other contributors. Adapted to OpenDocumentSpreadsheets's model:
#   - getters report the style a cell resolves to (D-032): every font has a size and a name
#     (LibreOffice's defaults, Liberation Sans 10, in a new file), there is no default
#     colour, and an unformatted cell reports the defaults rather than `nothing`
#   - empty cells are formatted, and whole columns and rows are not clipped to the used
#     area (D-033): XLSX.jl's out-of-dimension errors become successes
#   - pattern fills are blended into one colour (D-036); colours are rgb only
#   - setters return the cell's style name for a single cell (D-032)

using OpenDocumentSpreadsheets: ODSError, getFont, getFill, getBorder, getAlignment, getDefaultFont, effective_style, style_name
import ZipArchives

ctmp(name) = joinpath(mktempdir(), name)
# a font dict: LibreOffice's default size and name unless given
fd(ps...) = merge(Dict{String,Union{Nothing,Dict{String,String}}}("sz" => Dict("val" => "10"), "name" => Dict("val" => "Liberation Sans")),
                  Dict{String,Union{Nothing,Dict{String,String}}}(ps...))
sz(x) = "sz" => Dict("val" => string(x))
nm(x) = "name" => Dict("val" => x)
rgb(x) = "color" => Dict("rgb" => x)
const B = "b" => nothing
const I = "i" => nothing
side(style, rgb = "FF000000") = Dict("style" => style, "rgb" => rgb)
bd(; left = nothing, right = nothing, top = nothing, bottom = nothing, diagonal = nothing) =
    Dict{String,Union{Nothing,Dict{String,String}}}("left" => left, "right" => right, "top" => top, "bottom" => bottom, "diagonal" => diagonal)
al(ps...) = Dict{String,Union{Nothing,Dict{String,String}}}("alignment" => Dict{String,String}(ps...))
cellstyle(s, ref) = style_name(OpenDocumentSpreadsheets.get_odsfile(s).styles, effective_style(s, row_number(CellRef(ref)), column_number(CellRef(ref))))

@testset "setFont (XLSX.jl)" begin
    f = newods()
    s = f[1]
    s["A1:B2"] = ""; s["D1:E2"] = ""
    setFont(s, "A1:A2"; bold = true, italic = true, size = 24, name = "Arial")
    setFont(s, "B1:B2"; bold = true, italic = false, size = 14, name = "Aptos")
    setFont(s, "D1:D2"; bold = false, italic = true, size = 34, name = "Berlin Sans FB Demi")
    setFont(s, "E1:E2"; bold = false, italic = false, size = 4, name = "Times New Roman")
    setUniformFont(s, "A1:B2,D1:E2"; color = "blue")       # uniform, on a list of ranges
    for c in ("A1", "B2", "D1", "E2")
        @test getFont(s, c).font == fd(B, I, sz(24), nm("Arial"), rgb("FF0000FF"))
    end

    f = newods()
    s = f[1]
    s["A1:Z26"] = ""
    setFont(s, "Sheet1!A1:A2"; bold = true, italic = true, size = 24, name = "Arial", color = "blue")
    @test getFont(s, "A1").font == fd(B, I, sz(24), nm("Arial"), rgb("FF0000FF"))
    setFont(s, "Sheet1!Y:Z"; bold = true, italic = false, size = 14, name = "Aptos", color = "blue")
    @test getFont(s, "Y20").font == fd(B, sz(14), nm("Aptos"), rgb("FF0000FF"))
    setFont(s, "Sheet1.2:3"; bold = false, italic = true, size = 34, name = "Berlin Sans FB Demi", color = "blue")
    @test getFont(s, "M3").font == fd(I, sz(34), nm("Berlin Sans FB Demi"), rgb("FF0000FF"))
    setFont(f, "Sheet1!A1:A2"; bold = false, italic = false, size = 14, name = "Aptos", color = "green")
    @test getFont(s, "A1").font == fd(sz(14), nm("Aptos"), rgb("FF008000"))
    setFont(f, "Sheet1!Y:Z"; bold = false, italic = true, size = 24, name = "Arial", color = "green")
    @test getFont(s, "Y20").font == fd(I, sz(24), nm("Arial"), rgb("FF008000"))
    setFont(f, "Sheet1!2:3"; bold = true, italic = false, size = 24, name = "Times New Roman", color = "green")
    @test getFont(s, "M3").font == fd(B, sz(24), nm("Times New Roman"), rgb("FF008000"))
    setFont(s, "E1,E2,G2:G4"; bold = false, italic = false, size = 4, name = "Times New Roman", color = "blue")
    @test getFont(s, "G3").font == fd(sz(4), nm("Times New Roman"), rgb("FF0000FF"))
    setFont(s, :, 15:16; bold = true, italic = false, size = 38, name = "Wingdings", color = "red")
    @test getFont(s, "P10").font == fd(B, sz(38), nm("Wingdings"), rgb("FFFF0000"))
    setFont(s, 15:16, :; bold = false, italic = true, size = 8, name = "Wingdings", color = "red")
    @test getFont(f, "Sheet1!T16").font == fd(I, sz(8), nm("Wingdings"), rgb("FFFF0000"))
    setFont(s, [20, 22, 24], :; bold = false, italic = true, size = 48, name = "Aptos", color = "red")
    @test getFont(f, "Sheet1!H22").font == fd(I, sz(48), nm("Aptos"), rgb("FFFF0000"))
    setUniformFont(s, [15, 16, 20, 22, 24], :; bold = false, italic = true, size = 28, name = "Aptos", color = "red")
    @test getFont(f, "Sheet1!H15").font == fd(I, sz(28), nm("Aptos"), rgb("FFFF0000"))
    @test getFont(f, "Sheet1!H22").font == fd(I, sz(28), nm("Aptos"), rgb("FFFF0000"))

    # attributes not given are kept
    f = newods()
    s = f[1]
    s["A1:B4"] = ""
    dname = getDefaultFont(s).font["name"]["val"]
    dsize = getDefaultFont(s).font["sz"]["val"]
    @test (dname, dsize) == ("Liberation Sans", "10")
    @test_throws ODSError setFont(s, "S2!A1"; bold = true, size = 24, name = "Arial")      # another sheet
    setFont(s, "A1"; bold = true, size = 24, name = "Arial")
    @test getFont(s, "A1").font == fd(B, sz(24), nm("Arial"))
    setFont(s, "A1"; size = 18)
    @test getFont(s, "A1").font == fd(B, sz(18), nm("Arial"))
    setFont(f, "Sheet1!A1"; bold = false, size = 24, name = "Aptos")
    @test getFont(f, "Sheet1!A1").font == fd(sz(24), nm("Aptos"))
    @test getFont(f, "Sheet1!A1").fontId == getFont(s, "A1").fontId
    @test getFont(f, "Sheet1.A1").applyFont == getFont(s, "A1").applyFont == "1"
    setFont(s, "A2"; size = 18)
    @test getFont(s, "A2").font == fd(sz(18))
    setFont(s, "A3"; italic = true, name = "Berlin Sans FB Demi")
    @test getFont(s, "A3").font == fd(I, nm("Berlin Sans FB Demi"))
    setFont(s, "B1"; bold = true, italic = true, size = 14, color = "FF00FF00")
    @test getFont(s, "B1").font == fd(B, I, sz(14), rgb("FF00FF00"))
    setFont(f, "Sheet1!B1"; bold = false, italic = false, size = 12, name = "Berlin Sans FB Demi")
    @test getFont(f, "Sheet1!B1").font == fd(sz(12), nm("Berlin Sans FB Demi"), rgb("FF00FF00"))
    setFont(s, "A1:B2"; size = 18, name = "Arial")
    @test getFont(s, "A1").font == fd(sz(18), nm("Arial"))
    @test getFont(s, "A2").font == fd(sz(18), nm("Arial"))
    @test getFont(s, "B1").font == fd(sz(18), nm("Arial"), rgb("FF00FF00"))
    p = writeods(ctmp("fonts.ods"), f)
    openods(p) do r
        @test getFont(r, "Sheet1.A1").font == fd(sz(18), nm("Arial"))
        @test getFont(r[1], "A3").font == fd(I, nm("Berlin Sans FB Demi"))
        @test getFont(r[1], "B1").font == fd(sz(18), nm("Arial"), rgb("FF00FF00"))
    end
    setUniformFont(s, "A1:B4"; size = 12, name = "Times New Roman", color = "FF040404")
    for c in ("A1", "A4", "B3", "B4")
        @test getFont(s, c).font == fd(sz(12), nm("Times New Roman"), rgb("FF040404"))
    end

    f = newods()
    s = f[1]
    s["A1:E5"] = ""
    setFont(s, :, [1, 2, 3, 4, 5]; size = 18, name = "Arial", color = "FF040404")
    setFont(s, 1:3, [1, 3]; size = 12, name = "Aptos", color = "FF040408")
    setFont(s, [4, 5], [2, 4]; size = 6, name = "Courier New", color = "FF040400")
    @test getFont(s, "A4").font == fd(sz(18), nm("Arial"), rgb("FF040404"))
    @test getFont(s, "A3").font == fd(sz(12), nm("Aptos"), rgb("FF040408"))
    @test getFont(f, "Sheet1!D5").font == fd(sz(6), nm("Courier New"), rgb("FF040400"))
    # past the used area: formatted, not refused (D-033)
    setFont(s, "1:10"; size = 18, name = "Arial", color = "FF040404")
    @test getFont(s, "K10").font == fd(sz(18), nm("Arial"), rgb("FF040404"))
    setFont(s, "A:K"; size = 9)
    @test getFont(s, "K100").font["sz"] == Dict("val" => "9")
    for bad in ("Sheet1!garbage", "garbage", "garbage1:garbage2")
        @test_throws ODSError setFont(s, bad; size = 18)
    end
    @test_throws ODSError setFont(f, "Sheet1!garbage"; size = 18)

    f = newods()
    s = f[1]
    s["A1:E5"] = ""
    setUniformFont(s, "Sheet1!A1:E1"; size = 18, name = "Arial", color = "FF040404")
    @test getFont(s, "D1").font == fd(sz(18), nm("Arial"), rgb("FF040404"))
    setUniformFont(s, "Sheet1!2:3"; size = 18, name = "Arial", color = "FF040408")
    @test getFont(s, "A3").font == fd(sz(18), nm("Arial"), rgb("FF040408"))
    setUniformFont(s, "Sheet1!D:E"; size = 18, name = "Arial", color = "FF040400")
    @test getFont(s, "E5").font == fd(sz(18), nm("Arial"), rgb("FF040400"))
    setUniformFont(s, :, 1; size = 18, name = "Arial", color = "FF040404")
    @test getFont(s, "A3").font == fd(sz(18), nm("Arial"), rgb("FF040404"))
    setUniformFont(s, [1, 3, 4], 5; size = 18, name = "Arial", color = "FF040300")
    @test getFont(s, "E1").font == fd(sz(18), nm("Arial"), rgb("FF040300"))
    setUniformFont(s, [2, 3, 4], [3, 4]; size = 18, name = "Arial", color = "FF030308")
    @test getFont(s, "C3").font == fd(sz(18), nm("Arial"), rgb("FF030308"))
    setUniformFont(s, :; size = 8, name = "Arial", color = "FF030408")
    @test getFont(s, "D4").font == fd(sz(8), nm("Arial"), rgb("FF030408"))
    setUniformFont(s, :, :; size = 28, name = "Arial", color = "FF030408")
    @test getFont(s, "D4").font == fd(sz(28), nm("Arial"), rgb("FF030408"))
    @test getFont(s, "XFD1048576").font == fd(sz(28), nm("Arial"), rgb("FF030408"))    # the whole sheet
    for bad in ("Sheet1!garbage", "garbage", "garbage1:garbage2")
        @test_throws ODSError setUniformFont(s, bad; size = 18)
    end
end

@testset "setFont: keywords" begin
    f = newods(); s = f[1]
    setFont(s, "A1"; under = "single", strike = true)
    @test getFont(s, "A1").font == fd("u" => nothing, "strike" => nothing)
    setFont(s, "A1"; under = "double")
    @test getFont(s, "A1").font["u"] == Dict("val" => "double")
    setFont(s, "A1"; under = "none", strike = false)
    @test getFont(s, "A1").font == fd()
    setFont(s, "A2"; size = 10.5)
    @test getFont(s, "A2").font["sz"] == Dict("val" => "10.5")
    @test setFont(s, "A3"; vertAlign = "baseline") isa String
    @test_throws ODSError setFont(s, "A3"; vertAlign = "superscript")           # D-036
    @test_throws ODSError setFont(s, "A3"; under = "triple")
    @test_throws ODSError setFont(s, "A3"; size = 0)
    @test_throws ODSError setFont(s, "A3"; color = "notAcolor")
    @test_throws ODSError setFont(s, "A3"; weight = 3)                           # unknown keyword
    @test getFont(s, "Z99").font == fd() && getFont(s, "Z99").applyFont == "0"   # an empty, unformatted cell
end

@testset "setBorder (XLSX.jl)" begin
    f = newods()
    s = f[1]
    s[1:6, 1:6] = ""
    setBorder(s, "B2:E5"; outside = ["color" => "FFFF0000", "style" => "thick"])
    t = side("thick", "FFFF0000")
    @test getBorder(s, "B2").border == bd(left = t, top = t)
    @test getBorder(s, "B3").border == bd(left = t)
    @test getBorder(s, "B5").border == bd(left = t, bottom = t)
    @test getBorder(s, "C2").border == bd(top = t)
    @test getBorder(s, "C3").border == bd()
    @test getBorder(s, "C5").border == bd(bottom = t)
    @test getBorder(s, "E2").border == bd(right = t, top = t)
    @test getBorder(s, "E5").border == bd(right = t, bottom = t)
    setBorder(s, "B2:E5"; outside = ["color" => "dodgerblue4"])                   # the style is kept
    t = side("thick", "FF104E8B")
    @test getBorder(s, "B2").border == bd(left = t, top = t)
    @test getBorder(s, "C4").border == bd()

    f = newods()
    s = f[1]
    s[1:6, 1:6] = ""
    setBorder(s, "Sheet1!A1"; allsides = ["color" => "FFFF00FF", "style" => "thick"])
    t = side("thick", "FFFF00FF")
    @test getBorder(s, "A1").border == bd(left = t, right = t, top = t, bottom = t)
    setBorder(s, "Sheet1!A:E"; left = ["color" => "FFFF0001", "style" => "thick"])
    @test getBorder(s, "B2").border == bd(left = side("thick", "FFFF0001"))
    setBorder(s, "Sheet1!3:4"; left = ["color" => "FFFF0002", "style" => "thick"])
    @test getBorder(s, "B4").border == bd(left = side("thick", "FFFF0002"))
    setBorder(s, "B2,B4"; left = ["color" => "FFFF0004", "style" => "thick"])
    @test getBorder(s, "B2").border == bd(left = side("thick", "FFFF0004"))
    @test getBorder(s, "B3").border == bd(left = side("thick", "FFFF0002"))

    f = newods()
    s = f[1]
    setBorder(f, "Sheet1!D6"; left = ["style" => "dotted", "color" => "FF000FF0"], right = ["style" => "medium", "color" => "FF765000"],
              top = ["style" => "thick", "color" => "FF230000"], bottom = ["style" => "medium", "color" => "FF0000FF"],
              diagonal = ["style" => "dotted", "color" => "FF00D4D4"])
    @test getBorder(s, "D6").border == bd(left = side("dotted", "FF000FF0"), right = side("medium", "FF765000"),
        top = side("thick", "FF230000"), bottom = side("medium", "FF0000FF"),
        diagonal = Dict("style" => "dotted", "rgb" => "FF00D4D4", "direction" => "both"))
    setBorder(s, "D6"; left = ["style" => "hair"], right = ["color" => "FF111111"], diagonal = ["direction" => "up"])
    b = getBorder(s, "D6").border
    @test b["left"] == side("hair", "FF000FF0") && b["right"] == side("medium", "FF111111")
    @test b["diagonal"] == Dict("style" => "dotted", "rgb" => "FF00D4D4", "direction" => "up")
    @test_throws ODSError setBorder(s, "D6"; outside = ["style" => "thick"])                 # a single cell
    @test_throws ODSError setBorder(s, "D6:E7"; outside = ["style" => "thick"], left = ["style" => "thin"])
    @test_throws ODSError setBorder(s, "D6:E7,G1"; outside = ["style" => "thick"])
    @test_throws ODSError setBorder(s, "D6"; allsides = ["style" => "thin"], left = ["style" => "thin"])
    @test_throws ODSError setBorder(s, "D6"; left = ["style" => "wavy"])
    @test_throws ODSError setBorder(s, "D6"; diagonal = ["style" => "thin", "direction" => "sideways"])
    @test_throws ODSError setUniformBorder(s, "D6:E7"; outside = ["style" => "thick"])
    @test setBorder(s, "A10:C12"; outside = ["style" => "thin"]) == -1
    @test getBorder(s, "A12").border == bd(left = side("thin"), bottom = side("thin"))
end

@testset "border styles round trip (F-032)" begin
    f = newods(); s = f[1]
    styles = ("thin", "medium", "thick", "hair", "dotted", "dashed", "mediumDashed", "dashDot", "mediumDashDot",
              "dashDotDot", "mediumDashDotDot", "slantDashDot", "double")
    for (i, st) in enumerate(styles)
        setBorder(s, i, 1; allsides = ["style" => st, "color" => "red"])
    end
    r = openods(writeods(ctmp("borders.ods"), f))
    for (i, st) in enumerate(styles)
        @test getBorder(r[1], i, 1).border["top"] == side(st, "FFFF0000")
    end
    setBorder(s, "B1"; allsides = ["style" => "thin"])
    setBorder(s, "B1"; top = ["style" => "none"])
    @test getBorder(s, "B1").border == bd(left = side("thin"), right = side("thin"), bottom = side("thin"))
end

@testset "setFill (XLSX.jl)" begin
    f = newods(); s = f[1]
    @test getFill(s, "A1").fill == Dict("patternFill" => Dict("patternType" => "none"))
    setFill(s, "D17"; pattern = "solid", fgColor = "FF222222")
    @test getFill(s, "D17").fill == Dict("patternFill" => Dict("patternType" => "solid", "fgrgb" => "FF222222"))
    # patterns are blended, as LibreOffice blends them (D-036, experiment 013)
    setFill(s, "D18"; pattern = "darkTrellis", fgColor = "FF0000", bgColor = "0000FF")
    @test getFill(s, "D18").fill["patternFill"]["fgrgb"] == "FFBF0040"
    setFill(s, "D19"; pattern = "lightGrid", fgColor = "FF0000", bgColor = "0000FF")
    @test getFill(s, "D19").fill["patternFill"]["fgrgb"] == "FF6F0090"
    setFill(s, "D20"; pattern = "gray0625", fgColor = "FF0000", bgColor = "0000FF")
    @test getFill(s, "D20").fill["patternFill"]["fgrgb"] == "FF0F00F0"
    setFill(s, "D17"; fgColor = "yellow")                                     # a new colour for the fill there is
    @test getFill(s, "D17").fill["patternFill"]["fgrgb"] == "FFFFFF00"
    setFill(s, "E1"; fgColor = "yellow")                                      # no fill: nothing to colour
    @test getFill(s, "E1").fill["patternFill"]["patternType"] == "none"
    setFill(s, "D17"; pattern = "none")
    @test getFill(s, "D17").fill == Dict("patternFill" => Dict("patternType" => "none"))
    @test_throws ODSError setFill(s, "A1"; pattern = "darkTrellis", fgColor = "notAcolor")
    @test_throws ODSError setFill(s, "A1"; pattern = "notApattern")
    @test_throws ODSError setFill(s, "A1"; pattern = "solid", fgColor = "FFDDDDDDFF")
    @test_throws ODSError getFill(s, "A1:B2")                                 # getters take one cell
    setUniformFill(s, "B3:D5"; pattern = "solid", fgColor = "FF0000FF")
    for c in ("B3", "C4", "D5")
        @test getFill(s, c).fill == Dict("patternFill" => Dict("patternType" => "solid", "fgrgb" => "FF0000FF"))
    end
    setUniformFill(s, "F1,B3:C4")                                             # copy F1's (none) fill
    @test getFill(s, "C4").fill["patternFill"]["patternType"] == "none" && getFill(s, "D5").fill["patternFill"]["patternType"] == "solid"
end

@testset "setAlignment (XLSX.jl)" begin
    f = newods()
    s = f[1]
    setAlignment(s, "Sheet1!A1"; horizontal = "right", vertical = "justify", wrapText = true)
    @test getAlignment(s, "A1").alignment == al("horizontal" => "right", "vertical" => "justify", "wrapText" => "1")
    setAlignment(s, "Sheet1!A2:C4"; horizontal = "right", vertical = "justify", wrapText = true)
    @test getAlignment(s, "B3").alignment == al("horizontal" => "right", "vertical" => "justify", "wrapText" => "1")
    setAlignment(s, "Sheet1!D:E"; horizontal = "right", vertical = "justify", wrapText = true)
    @test getAlignment(s, "D26").alignment == al("horizontal" => "right", "vertical" => "justify", "wrapText" => "1")
    setAlignment(s, "Sheet1!25:26"; horizontal = "left", vertical = "top", wrapText = false)
    @test getAlignment(s, "D26").alignment == al("horizontal" => "left", "vertical" => "top", "wrapText" => "0")
    setAlignment(s, "G8,H10,J15:M18"; horizontal = "left", vertical = "bottom", wrapText = true)
    @test getAlignment(s, "L16").alignment == al("horizontal" => "left", "vertical" => "bottom", "wrapText" => "1")

    f = newods()
    s = f[1]
    setAlignment(s, :, 1:3; horizontal = "right", vertical = "justify", wrapText = true)
    @test getAlignment(s, "B25").alignment == al("horizontal" => "right", "vertical" => "justify", "wrapText" => "1")
    setAlignment(s, 8:2:16, :; horizontal = "right", vertical = "justify", wrapText = true)
    @test getAlignment(s, "C12").alignment == al("horizontal" => "right", "vertical" => "justify", "wrapText" => "1")
    setAlignment(s, :, [8, 10, 12, 14, 16]; horizontal = "right", vertical = "top", wrapText = true)
    @test getAlignment(s, "L22").alignment == al("horizontal" => "right", "vertical" => "top", "wrapText" => "1")
    setAlignment(s, 18, 20:3:26; horizontal = "left", vertical = "top", wrapText = true)
    @test getAlignment(s, "W18").alignment == al("horizontal" => "left", "vertical" => "top", "wrapText" => "1")
    setAlignment(s, 18:2:22, 20:3:26; horizontal = "left", vertical = "bottom", wrapText = true)
    @test getAlignment(s, "Z20").alignment == al("horizontal" => "left", "vertical" => "bottom", "wrapText" => "1")
    @test getAlignment(s, "Y20").alignment == al()
    setUniformAlignment(s, "B3:D5"; horizontal = "center", vertical = "center", wrapText = true)
    @test getAlignment(s, "D5").alignment == al("horizontal" => "center", "vertical" => "center", "wrapText" => "1")
    setAlignment(s, "Y30"; horizontal = "fill", shrink = true, indent = 2, rotation = -45)
    @test getAlignment(s, "Y30").alignment == al("horizontal" => "fill", "shrinkToFit" => "1", "indent" => "2", "textRotation" => "-45")
    p = writeods(ctmp("align.ods"), f)
    @test getAlignment(openods(p)[1], "Y30").alignment == getAlignment(s, "Y30").alignment
    @test_throws ODSError setAlignment(s, "A1"; horizontal = "middle")
    @test_throws ODSError setAlignment(s, "A1"; rotation = 91)
    @test_throws ODSError setAlignment(s, "A1"; indent = -1)
end

@testset "UniformStyle (XLSX.jl)" begin
    f = newods()
    s = f[1]
    setFont(s, "A1:F5"; size = 18, name = "Arial")
    st = cellstyle(s, "A1")
    @test setUniformStyle(s, "A1:F5") == st
    @test cellstyle(s, "F5") == st
    setFont(s, "A6:F10"; size = 10, name = "Aptos")
    st = cellstyle(s, "E6")
    @test setUniformStyle(s, [6, 7, 8, 9, 10], 5) == st && cellstyle(s, "E8") == st
    setFont(s, "A16"; size = 80, name = "Ariel")
    st = cellstyle(s, "A16")
    @test setUniformStyle(s, "A16,A15,D20:E25,F25") == st
    @test cellstyle(s, "A15") == st && cellstyle(s, "D20") == st && cellstyle(s, "F25") == st
    setFont(s, "A1"; size = 8, name = "Aptos")
    st = cellstyle(s, "A1")
    @test setUniformStyle(s, "Sheet1!1:2") == st && cellstyle(s, "M2") == st
    @test setUniformStyle(s, "Sheet1!B:C") == st && cellstyle(s, "C300") == st
    @test setUniformStyle(s, :) == st && cellstyle(s, "Z26") == st
end

@testset "formatting keeps values, and named styles stay parents" begin
    xf = openods(joinpath(DATA, "lo-scenarios.ods"); mode = "rw")
    ws = xf["S05-styled-empty"]
    @test ws["A1"] === Int64(1)
    setFont(ws, "A1"; bold = true)
    @test ws["A1"] === Int64(1) && getFont(ws, "A1").font["b"] === nothing
    setFill(ws, "D20"; pattern = "solid", fgColor = "00FF00")                 # a styled empty cell
    @test getFill(ws, "D20").fill["patternFill"]["fgrgb"] == "FF00FF00"
    # a cell in a named style: the new style derives from it
    st = xf.styles
    OpenDocumentSpreadsheets.restyle_cells!(_ -> OpenDocumentSpreadsheets.style_id(st, "Heading"), ws, 5:5, 1:1)
    setFont(ws, "A5"; italic = true)
    cs = OpenDocumentSpreadsheets.cell_style(st, effective_style(ws, 5, 1))
    @test cs.parent == "Heading" && getFont(ws, "A5").font["sz"] == Dict("val" => "24") && haskey(getFont(ws, "A5").font, "i")
    back = openods(writeods(ctmp("named.ods"), xf))
    bw = back["S05-styled-empty"]
    @test getFont(bw, "A5").font == getFont(ws, "A5").font
    @test getFill(bw, "D20").fill == getFill(ws, "D20").fill && bw["A1"] === Int64(1)
    @test getFont(bw, "A1").font["b"] === nothing
end

@testset "getters on read-only files, and through names" begin
    xf = openods(joinpath(DATA, "lo-scenarios.ods"))                         # read-only
    ws = xf["S05-styled-empty"]
    @test getFill(ws, "D20").fill["patternFill"]["patternType"] == "solid"
    @test getFill(xf, "S05-styled-empty.D20").fill == getFill(ws, 20, 4).fill
    @test getFont(ws, "A1").font["name"]["val"] isa String
    @test_throws ODSError setFont(ws, "A1"; bold = true)                       # read-only
    xt = openods(joinpath(DATA, "lo-tables.ods"))
    for dn in OpenDocumentSpreadsheets.defined_names(xt)
        dn.range === nothing && continue
        v = OpenDocumentSpreadsheets.get_defined_name_value(dn)
        v isa OpenDocumentSpreadsheets.SheetCellRef && @test getFont(xt, dn.name).fontId isa String
    end
end

@testset "patched files: formatting changes only the formatted cells (D-023)" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    xf = openods(src; mode = "rw")
    ws = xf["S01-gaps"]
    setFont(ws, "C1"; bold = true, name = "Courier New")
    p = writeods(ctmp("p.ods"), xf)
    orig = openods(src); back = openods(p)
    for k in 1:sheetcount(back)
        sheetnames(back)[k] == "S01-gaps" && continue
        @test String(OpenDocumentSpreadsheets.XML.sourcetext(back[k].entry.node)) == String(OpenDocumentSpreadsheets.XML.sourcetext(orig[k].entry.node))
    end
    @test getFont(back["S01-gaps"], "C1").font["name"] == Dict("val" => "Courier New")
    @test back["S01-gaps"]["C1"] === Int64(3)
    c = OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(read(p)), :content)
    @test count("<style:font-face style:name=\"Courier New\"", c) == 1         # declared once, with the others
end

@testset "LibreOffice keeps fonts, fills, borders and alignment" begin
    if lo_ok(; what = "the cell format oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        f = newods("F"); s = f["F"]
        s["A1"] = "text"; s["B2"] = 2.5
        setFont(s, "A1"; bold = true, italic = true, size = 14, name = "Courier New", color = "red", under = "double", strike = true)
        setFill(s, "B2"; pattern = "solid", fgColor = "FFFF00")
        setBorder(s, "C3"; left = ["style" => "thick", "color" => "blue"], top = ["style" => "dashed"], bottom = ["style" => "double"],
                  diagonal = ["style" => "thin", "direction" => "down"])
        setAlignment(s, "D4"; horizontal = "center", vertical = "top", wrapText = true, indent = 1, rotation = 90)
        setFont(s, :, 6; italic = true)
        setFill(s, 8, :; pattern = "solid", fgColor = "00FF00")
        x = openods(joinpath(DATA, "lo-scenarios.ods"); mode = "rw")
        setFont(x["S01-gaps"], "A1:C1"; bold = true, name = "Courier New")
        f1 = writeods(joinpath(dir, "new.ods"), f)
        f2 = writeods(joinpath(dir, "patched.ods"), x)
        lo_convert([f1, f2], "ods"; outdir = joinpath(dir, "lo"), profile = profile)
        r = openods(joinpath(dir, "lo", "new.ods"))
        rs = r["F"]
        for c in ("A1", "B2", "C3", "D4", "F100", "Z8", "A1:A1")
            c == "A1:A1" && continue
            @test getFont(rs, c).font == getFont(s, c).font
            @test getFill(rs, c).fill == getFill(s, c).fill
            @test getBorder(rs, c).border == getBorder(s, c).border
            @test getAlignment(rs, c).alignment == getAlignment(s, c).alignment
        end
        @test rs["A1"] == "text" && rs["B2"] == 2.5
        r2 = openods(joinpath(dir, "lo", "patched.ods"))["S01-gaps"]
        @test getFont(r2, "C1").font["name"] == Dict("val" => "Courier New") && haskey(getFont(r2, "A1").font, "b")
        @test r2["C1"] === Int64(3)
    end
end

@testset "styles no cell uses are not written (D-046)" begin
    content(p) = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(p)), "content.xml"))
    f = newods(); s = f[1]
    s["A1"] = 1.5
    n1 = setFont(s, "A1"; bold = true)
    n2 = setFont(s, "A1"; italic = true)
    setFormat(s, "A1"; format = "0.000")
    n3 = setFormat(s, "A1"; format = "0.00")
    setColumnWidth(s, "A"; width = 10); setColumnWidth(s, "A"; width = 20)
    @test length(unique([n1, n2, n3])) == 3
    p = writeods(ctmp("prune.ods"), f)
    c = content(p)
    @test occursin("style:name=\"$n3\"", c) && !occursin("style:name=\"$n1\"", c) && !occursin("style:name=\"$n2\"", c)
    @test occursin("number:decimal-places=\"2\"", c) && !occursin("number:decimal-places=\"3\"", c)
    @test count("style:family=\"table-column\"", c) == 1
    r = openods(p)[1]
    @test OpenDocumentSpreadsheets.getText(r, "A1") == "1.50" && haskey(getFont(r, "A1").font, "b") && haskey(getFont(r, "A1").font, "i")
    @test OpenDocumentSpreadsheets.getColumnWidth(r, "A1") ≈ 20.7109375
    # the model keeps every style: a pruned one used again is written again
    s["B1"] = 2.5
    @test setFont(s, "B1"; bold = true) == n1
    c = content(writeods(ctmp("prune2.ods"), f))
    @test occursin("style:name=\"$n1\"", c) && !occursin("style:name=\"$n2\"", c)
    # a patched file: only the styles the edited cells keep are added
    q = ctmp("lo.ods"); cp(joinpath(DATA, "lo-values.ods"), q)
    g = openods(q; mode = "rw"); w = g[1]
    a = setFill(w, "A1"; pattern = "solid", fgColor = "FF0000")
    b = setFill(w, "A1"; pattern = "solid", fgColor = "00FF00")
    c = content(writeods(ctmp("lo2.ods"), g))
    @test occursin("style:name=\"$b\"", c) && !occursin("style:name=\"$a\"", c)
    @test getFill(openods(ctmp("lo2.ods") |> x -> writeods(x, g))[1], "A1").fill["patternFill"]["fgrgb"] == "FF00FF00"
end

@testset "setFont keeps each cell's other font properties; setUniformFont doesn't" begin
    f = newods(); s = f[1]
    s[1:1000, 1] = collect(1:1000)
    s[1:1000, 2] = collect(1:1000)
    colours = [string(k * 16_000; base = 16, pad = 6) for k in 1:1000]      # 1,000 different colours
    for k in 1:1000
        setFont(s, k, 1; color = colours[k]); setFont(s, k, 2; color = colours[k])
    end
    @test setFont(s, "A1:A1000"; bold = true) == -1
    fa = [getFont(s, k, 1).font for k in 1:1000]
    @test all(haskey(fa[k], "b") && fa[k]["color"]["rgb"] == "FF" * uppercase(colours[k]) for k in 1:1000)
    setUniformFont(s, "B1:B1000"; bold = true)
    fb = [getFont(s, k, 2).font for k in 1:1000]
    @test all(fb[k] == fb[1] for k in 1:1000)
    @test haskey(fb[1], "b") && fb[1]["color"]["rgb"] == "FF" * uppercase(colours[1])
    @test length(unique(effective_style(s, k, 2) for k in 1:1000)) == 1
    # and so after saving
    r = openods(writeods(ctmp("colours.ods"), f))[1]
    @test getFont(r, 777, 1).font["color"]["rgb"] == "FF" * uppercase(colours[777]) && haskey(getFont(r, 777, 1).font, "b")
    @test getFont(r, 777, 2).font == fb[1]
end

@testset "a refused format call changes nothing (code review, Phase 1 item 8)" begin
    O = OpenDocumentSpreadsheets
    sheet_of(xf) = O.stylesheet(xf.styles)
    # read-only: an outside border was drawn all the same
    ro = openods(joinpath(DATA, "lo-scenarios.ods"))
    ws = ro[1]
    before = [O.effective_style(ws, r, c) for r in 1:4, c in 1:4]
    err = try setBorder(ws, "A1:C3"; outside = ["style" => "thin"]); nothing catch e; e end
    @test err isa ODSError && occursin("read-only", err.msg)
    @test [O.effective_style(ws, r, c) for r in 1:4, c in 1:4] == before
    # a read-only file or a bad reference: no font face or data style is added first
    for (xf, ref) in ((ro, "A1"), (newods(), "NoSuchSheet.A1"), (newods(), "A1:"))
        w = xf[1]
        faces = copy(sheet_of(xf).added_faces); codes = copy(sheet_of(xf).code_styles)
        x = ref == "NoSuchSheet.A1" ? xf : w
        @test_throws ODSError setFont(x, ref; name = "Quirky Font")
        @test_throws ODSError setUniformFont(x, ref; name = "Quirky Font")
        @test_throws ODSError setFormat(x, ref; format = "0.0000")
        @test_throws ODSError setUniformFormat(x, ref; format = "0.0000")
        @test sheet_of(xf).added_faces == faces && sheet_of(xf).code_styles == codes
    end
end
