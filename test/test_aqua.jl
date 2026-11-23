# Package quality checks (Aqua.jl): method ambiguities, unbound type parameters, undefined
# exports, project compat entries, stale dependencies, type piracy and persistent tasks.
import Aqua

Aqua.test_all(OpenDocumentSpreadsheets)
