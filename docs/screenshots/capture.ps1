# Opens a file in LibreOffice's GUI with a throwaway profile, sizes its window, waits until it has drawn,
# and saves the window, or a part of it, as a PNG. Physical pixels (the process is DPI aware). Made in
# experiment 041; see README.md here.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture.ps1 -File x.ods -Out x.png -LoProfile dir
#       [-Width 2400 -Height 1300] [-Cells CxR [-Bar]] [-Tabs] [-Crop "x,y,w,h"] [-Keys "%{DOWN}"] [-Keep]
#
# -Cells CxR  the row and column headers and the first C visible columns and R visible rows
# -Bar        with -Cells, the formula bar above them too
# -Tabs       the sheet tabs
# -Crop       a rectangle of the window
# -Keys       keystrokes sent once the window has drawn (SendKeys' form: % Alt, ^ Ctrl, + Shift)
param(
    [Parameter(Mandatory)] [string] $File,
    [Parameter(Mandatory)] [string] $Out,
    [Parameter(Mandatory)] [string] $LoProfile,
    [int] $Width = 2400,
    [int] $Height = 1300,
    [string] $Cells = "",
    [switch] $Bar,
    [switch] $Tabs,
    [string] $Crop = "",
    [string] $Keys = "",
    [int] $TimeoutSec = 90,
    [switch] $Keep
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
}
"@
[void][W]::SetProcessDPIAware()

# soffice.com, as the headless runs use it. The profile must exist (make_screenshots.jl makes it with a
# headless run first): a profile URL LibreOffice can't use shows a "corrupt bootstrap.ini" dialog.
$soffice = "C:\Program Files\LibreOffice\program\soffice.com"
$file = (Resolve-Path $File).Path
$LoProfile = [IO.Path]::GetFullPath($LoProfile)
if (-not (Test-Path "$LoProfile\user")) { throw "No profile at ${LoProfile}: make it with a headless run first" }
$profUrl = "file:///" + ($LoProfile -replace '\\', '/')
$leaf = [IO.Path]::GetFileName($file)

$argline = "`"-env:UserInstallation=$profUrl`" --norestore --nologo `"$file`""
$null = Start-Process -FilePath $soffice -PassThru -WindowStyle Hidden -ArgumentList $argline

# The frame whose title names the file, owned by a soffice.bin running with this profile. Hidden or not:
# the launcher's hidden console passes SW_HIDE on to LibreOffice's first frame, which is shown below.
function Find-Window {
    $bins = Get-CimInstance Win32_Process -Filter "Name='soffice.bin'" |
        Where-Object { $_.CommandLine -like "*$($LoProfile -replace '\\','/')*" }
    $pids = @($bins | ForEach-Object { [uint32]$_.ProcessId })
    $script:found = [IntPtr]::Zero
    $cb = [W+EnumProc]{
        param($h, $p)
        $wpid = [uint32]0
        [void][W]::GetWindowThreadProcessId($h, [ref]$wpid)
        if ($pids -contains $wpid) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][W]::GetWindowText($h, $sb, 512)
            if ($sb.ToString() -like "$leaf*") { $script:found = $h; return $false }
        }
        return $true
    }
    [void][W]::EnumWindows($cb, [IntPtr]::Zero)
    return @{ Hwnd = $script:found; Pids = $pids }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Milliseconds 250
    $w = Find-Window
} while ($w.Hwnd -eq [IntPtr]::Zero -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec)
if ($w.Hwnd -eq [IntPtr]::Zero) { throw "No LibreOffice window for $leaf after $TimeoutSec s" }
$h = $w.Hwnd

try {
    [void][W]::ShowWindow($h, 1)   # SW_SHOWNORMAL: not maximised
    [void][W]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $Width, $Height, 0x0040)   # SWP_SHOWWINDOW
    [void][W]::SetForegroundWindow($h)

    function Get-Shot {
        # The visible frame (DWMWA_EXTENDED_FRAME_BOUNDS), without Windows 11's invisible resize borders.
        $r = New-Object W+RECT
        if ([W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { [void][W]::GetWindowRect($h, [ref]$r) }
        $bmp = New-Object System.Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
        $g.Dispose()
        return $bmp
    }
    function Get-Hash($bmp) {
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
        $sha = [Security.Cryptography.SHA1]::Create()
        $x = [BitConverter]::ToString($sha.ComputeHash($ms.ToArray()))
        $ms.Dispose(); return $x
    }
    # Waits until two shots 700 ms apart are identical (the window has finished drawing), at least
    # `$first` ms in, and returns the last. It keeps the window in front, unless `$refocus` is false:
    # after keystrokes, bringing the frame forward would close the drop-down or popup they opened.
    function Wait-Stable($first, $refocus = $true) {
        Start-Sleep -Milliseconds $first
        $prev = Get-Shot; $prevH = Get-Hash $prev
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 700
            if ($refocus) { [void][W]::SetForegroundWindow($h) }
            $cur = Get-Shot; $curH = Get-Hash $cur
            $prev.Dispose(); $prev = $cur
            if ($curH -eq $prevH) { return $prev }
            $prevH = $curH
        }
        throw "The window kept changing"
    }

    $shot = Wait-Stable 2000
    if ($Keys -ne "") {
        $shot.Dispose()
        [void][W]::SetForegroundWindow($h)
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        $shot = Wait-Stable 1500 $false
    }

    # The grid's own lines: the column header's top line (A0A0A0, or 0069BC beside the cursor's column),
    # its column separators, and the row header's separators.
    function Test-GridLine($bmp, $x, $y) {
        $c = $bmp.GetPixel($x, $y); $v = "{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
        return ($v -eq 'A0A0A0' -or $v -eq '0069BC')
    }
    function Find-GridTop($bmp) {
        for ($y = 100; $y -lt $bmp.Height - 100; $y++) {
            if ((Test-GridLine $bmp 300 $y) -and (Test-GridLine $bmp 600 $y) -and (Test-GridLine $bmp 900 $y)) { return $y }
        }
        throw "No grid found"
    }
    if ($Cells -ne "") {
        $nc, $nr = $Cells.Split('x') | ForEach-Object { [int]$_ }
        $top = Find-GridTop $shot
        $left = 0; while ($left -lt 50 -and ("{0:X2}" -f $shot.GetPixel($left, $top + 2).R) -ne 'F0') { $left++ }
        # the row header's right edge: the first column line; outline buttons may sit to its left
        $cols = @(); for ($x = $left; $x -lt $shot.Width; $x++) { if (Test-GridLine $shot $x ($top + 2)) { $cols += $x } }
        $rows = @(); for ($y = $top + 2; $y -lt $shot.Height; $y++) { if (Test-GridLine $shot ($cols[0] - 3) $y) { $rows += $y } }
        if ($cols.Count -le $nc -or $rows.Count -le $nr) { throw "Only $($cols.Count - 1) columns and $($rows.Count - 1) rows visible" }
        # -Bar: from the formula bar's top, 40 px (at 150%) above the grid
        $y0 = if ($Bar) { $top - 40 } else { $top }
        $Crop = "{0},{1},{2},{3}" -f $left, $y0, ($cols[$nc] - $left + 1), ($rows[$nr] - $y0 + 1)
    }
    if ($Tabs) {
        # the tab bar: the band between the horizontal scroll bar and the status bar, 760 px wide
        $Crop = "{0},{1},{2},{3}" -f 0, ($shot.Height - 72), 760, 40
    }
    if ($Crop -ne "") {
        $c = $Crop.Split(',') | ForEach-Object { [int]$_ }
        $rect = New-Object System.Drawing.Rectangle $c[0], $c[1], $c[2], $c[3]
        $part = $shot.Clone($rect, $shot.PixelFormat)
        $shot.Dispose(); $shot = $part
    }
    $outPath = [IO.Path]::GetFullPath($Out)
    $shot.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $size = "$($shot.Width)x$($shot.Height)"
    $shot.Dispose()
    "{0:N1} s; {1} -> {2}" -f $sw.Elapsed.TotalSeconds, $size, $outPath
}
finally {
    if (-not $Keep) {
        foreach ($p in (Find-Window).Pids) { try { Stop-Process -Id $p -Force -ErrorAction Stop } catch {} }
    }
}
