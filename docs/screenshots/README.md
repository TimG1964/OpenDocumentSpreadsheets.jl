# The docs' pictures

The pictures in `docs/src/images/` are LibreOffice Calc windows, captured by script on Windows. A page
asks for one with a marker after the example that makes it:

````markdown
```@raw html
<!-- shot: chart_first cells=12x19 -->
```
![A description of the picture, for readers who can't see it](../images/chart_first.png)
````

The marker is an HTML comment in a raw HTML block. Julia's Markdown, which Documenter uses, has no HTML
comments: a bare one shows on the page as text, and joins the picture's paragraph, where an `_` in the
marker and one in the picture's path become emphasis and break the picture (issue #6).

## Making them

```
julia --project=. docs/screenshots/make_screenshots.jl            # every picture
julia --project=. docs/screenshots/make_screenshots.jl tables     # some, by name
```

You need Windows with LibreOffice installed (`ODS_SOFFICE` names its `soffice.com`, if it isn't in
`C:\Program Files\LibreOffice`) and an unlocked desktop. Each picture opens LibreOffice for about four
seconds, which takes the foreground, so don't type while the pictures are made. The script runs every
page's examples as `test/test_docs.jl` does (the harness is `test/docs_env.jl`). After a block with a
marker, it saves what the block made, sets the sheet's view, and runs `capture.ps1`, which opens the file
with a throwaway profile in `work/` and saves the window, or part of it, as a PNG.

The pictures are made at the screen's scale (150% here) with LibreOffice's default look, so they are
alike from one run to the next. The same run gives the same pictures byte for byte.

## Markers

`<!-- shot: NAME option … -->`, where NAME is the picture's file name without `.png`. Options:

| Option | |
|---|---|
| `cells=CxR` | the row and column headers and the first C columns and R rows |
| `bar` | with `cells`, the formula bar too |
| `tabs` | the sheet tabs |
| `preview` | the print preview (Ctrl+Shift+O) |
| `dropdown` | the cursor's drop-down list open (Alt+Down) |
| `file=x.ods` | the file the example saved, rather than the page's `xf` |
| `xf=name` | the page's variable holding the workbook (default `xf`) |
| `sheet=Name` | the sheet shown (default the first): it's moved to the front in the copy captured. Write a space in its name as `_` (`sheet=Costs_2027`) |
| `zoom=N` | the zoom, in percent (default 100) |
| `top=A1`, `top=keep` | the cell at the top left (default A1), or the one the example set |
| `cursor=A1`, `cursor=keep` | the cursor (default A1), or the one the example set |
| `size=WxH` | the window's size in pixels (default 2400x1300) |

`test/test_docs.jl` checks that every marker is in its raw HTML block, followed by its picture, that every picture has a
description and is used, and that the pictures stay under 3 MB in all.

How the capture works, and what was found on the way, is in the workspace's
`experiments/041-lo-screenshots/README.md`.

The throwaway profile has automatic spell check off, so codes and names aren't underlined. Keystrokes
(`dropdown`, `preview`) are sent once the window has drawn; the capture then waits without bringing the
window forward again, which would close a drop-down. Don't use the keyboard or switch windows while the
script runs: a key pressed then can land in a cell of the picture being made.
