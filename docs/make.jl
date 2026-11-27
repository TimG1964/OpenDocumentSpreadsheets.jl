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
        "Supported features" => "features.md",
        "Getting started" => Any[
            "Tutorial" => "tutorial/tutorial.md",
            "Creating and editing files" => "tutorial/creatingFiles.md",
            "Addressing cells and ranges" => "concepts/addressing.md",
            "Values and types" => "concepts/values.md",
        ],
        "Data" => Any[
            "Formulas" => "data/formulas.md",
            "Named ranges" => "data/namedRanges.md",
            "Database ranges" => "data/tables.md",
            "Validity" => "data/validity.md",
            "AutoFilter and sorting" => "data/autoFilter.md",
        ],
        "Formatting" => Any[
            "Cell formats" => "formatting/cellFormatting.md",
            "Conditional formats" => "formatting/conditionalFormatting.md",
            "Merged cells" => "formatting/mergedCells.md",
        ],
        "Layout and view" => Any[
            "Column width and row height" => "layout/widthAndHeight.md",
            "Inserting and deleting rows and columns" => "layout/insertDelete.md",
            "Hiding and grouping" => "layout/hideAndGroup.md",
            "Panes, the view and tab colours" => "layout/panesAndView.md",
        ],
        "Sheets" => Any[
            "Managing sheets" => "sheets/sheets.md",
            "Protecting sheets" => "sheets/protection.md",
            "Page setup and printing" => "sheets/printing.md",
            "Document properties" => "sheets/properties.md",
        ],
        "Pictures, notes and links" => Any[
            "Pictures" => "objects/pictures.md",
            "Notes and comments" => "objects/notes.md",
            "Hyperlinks" => "objects/hyperlinks.md",
        ],
        "Charts" => Any[
            "Overview" => "charts/overview.md",
            "Creating charts" => "charts/creating.md",
            "Formatting charts" => "charts/formatting.md",
            "Reading charts" => "charts/reading.md",
            "Sparklines" => "charts/sparklines.md",
        ],
        "Saving and large files" => "saving.md",
        "Coming from XLSX.jl" => "xlsx.md",
        "API reference" => Any[
            "Files, cells and tables" => "api.md",
            "Formatting" => "api-formatting.md",
            "Sheets and settings" => "api-sheets.md",
            "Links, notes and objects" => "api-objects.md",
            "Charts" => "api-charts.md",
            "Charts: every function" => "api-charts-all.md",
        ],
    ],
    checkdocs = :public,
    # The shared core is internal: its public names are bound in OpenDocumentSpreadsheets with
    # docstrings of their own (src/corenames.jl), and the core's own docstrings aren't shown.
    checkdocs_ignored_modules = [OpenDocumentSpreadsheets.SheetCore],
    # External links are checked only when asked, as they depend on other sites being up:
    # the CI job "Documentation links" sets DOCUMENTER_LINKCHECK=true.
    linkcheck = get(ENV, "DOCUMENTER_LINKCHECK", "false") == "true",
    # Not checked: the repo's files and the docs' own site, which may not hold a page until this
    # build is deployed (`stable/` only after a release).
    linkcheck_ignore = [r"^https://github\.com/TimG1964/OpenDocumentSpreadsheets\.jl/(blob|tree)/",
                        r"^https://TimG1964\.github\.io/OpenDocumentSpreadsheets\.jl/"],
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
