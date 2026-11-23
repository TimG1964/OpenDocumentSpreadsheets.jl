using Documenter, OpenDocumentSpreadsheets

makedocs(
    sitename = "OpenDocumentSpreadsheets.jl",
    authors = "Tim Gebbels",
    modules = [OpenDocumentSpreadsheets],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/stable/",
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => "tutorial.md",
        "Guide" => Any[
            "Cell values and types" => "guide/values.md",
            "References and names" => "guide/references.md",
            "Formulas" => "guide/formulas.md",
            "Formatting" => "guide/formatting.md",
            "Sheets, names and settings" => "guide/sheets.md",
            "Saving and writing" => "guide/saving.md",
        ],
        "Coming from XLSX.jl" => "xlsx.md",
        "API reference" => Any[
            "Files, cells and tables" => "api.md",
            "Formatting" => "api-formatting.md",
            "Sheets and settings" => "api-sheets.md",
            "Links, notes and objects" => "api-objects.md",
        ],
    ],
    checkdocs = :public,
    # External links are checked only when asked, as they depend on other sites being up:
    # the CI job "Documentation links" sets DOCUMENTER_LINKCHECK=true.
    linkcheck = get(ENV, "DOCUMENTER_LINKCHECK", "false") == "true",
    linkcheck_ignore = [r"^https://github\.com/TimG1964/OpenDocumentSpreadsheets\.jl/(blob|tree)/"],
)

deploydocs(
    repo = "github.com/TimG1964/OpenDocumentSpreadsheets.jl.git",
    devbranch = "master",
    target = "build",
    versions = [
        "stable" => "v^",
        "dev" => "dev",
    ],
)
