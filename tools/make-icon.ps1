<#
.SYNOPSIS
  Generates ClaudeBG.ico - the icon embedded into ClaudeBGTray.exe.

.DESCRIPTION
  The icon is a BUILD-TIME asset, not runtime state. It is generated once by this
  script, committed to the repo, and baked into the exe by csc:

    csc.exe ... /win32icon:ClaudeBG.ico tray\ClaudeBGTray.cs

  A Start Menu shortcut with no IconLocation override inherits its target's
  embedded icon, so nothing has to write an .ico at patch time and nothing has to
  clean one up at restore time. It also means the artwork exists exactly once and
  styles the exe everywhere Windows shows it - Explorer, Alt-Tab, the taskbar -
  rather than only on the shortcut.

  This script exists so the artwork stays reproducible from source. Change the
  three colour/geometry values below and re-run it; do not hand-edit the .ico.

  .NET has no multi-resolution ICO writer - Icon.Save round-trips a single image
  only - so the ICONDIR/ICONDIRENTRY container is assembled by hand below.
  16/32/48 are written as classic 32bpp DIBs and 256 as a PNG, which is the
  layout Windows and csc are both happiest with.

.EXAMPLE
  .\tools\make-icon.ps1
  .\tools\make-icon.ps1 -OutFile C:\tmp\preview.ico
#>
param(
    [string] $OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeBG.ico')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# --- The artwork. Kept identical to what the tray used to draw at runtime. -----
$GradientFrom = [System.Drawing.Color]::FromArgb(150, 60, 200)   # purple
$GradientTo   = [System.Drawing.Color]::FromArgb(255, 130, 60)   # orange
$RingColor    = [System.Drawing.Color]::FromArgb(230, 255, 255, 255)
$Sizes        = @(16, 32, 48, 256)

function New-DiscBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        # The original was a 28x28 disc inside 32x32 with a 2px ring, so the inset
        # and the pen both scale at 1/16th of the edge. At 16px that lands on a
        # 1px inset and a 1px ring, which is what keeps the ring from closing up.
        $inset = [Math]::Max(1, [int][Math]::Round($Size / 16.0))
        $penW  = [Math]::Max(1.0, $Size / 16.0)
        $rect  = New-Object System.Drawing.Rectangle($inset, $inset, ($Size - 2 * $inset), ($Size - 2 * $inset))

        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $GradientFrom, $GradientTo, 45.0)
        try { $g.FillEllipse($brush, $rect) } finally { $brush.Dispose() }

        $pen = New-Object System.Drawing.Pen($RingColor, $penW)
        try { $g.DrawEllipse($pen, $rect) } finally { $pen.Dispose() }
    } finally { $g.Dispose() }
    return $bmp
}

# A 32bpp ICO image is a BITMAPINFOHEADER whose biHeight is DOUBLE the real
# height (it covers the colour rows plus a legacy 1bpp AND mask), followed by
# bottom-up BGRA rows, followed by the AND mask. The mask is vestigial for 32bpp
# but Windows still expects the bytes to be there.
function ConvertTo-IcoDib {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width; $h = $Bitmap.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $andRowBytes = [int][Math]::Floor((($w + 31) / 32)) * 4   # 1bpp, 4-byte aligned
        $xorSize     = $w * $h * 4

        $bw.Write([uint32]40)        # biSize
        $bw.Write([int32]$w)         # biWidth
        $bw.Write([int32]($h * 2))   # biHeight - colour rows + mask rows
        $bw.Write([uint16]1)         # biPlanes
        $bw.Write([uint16]32)        # biBitCount
        $bw.Write([uint32]0)         # biCompression = BI_RGB
        $bw.Write([uint32]$xorSize)  # biSizeImage
        $bw.Write([int32]0); $bw.Write([int32]0)   # pels-per-meter
        $bw.Write([uint32]0); $bw.Write([uint32]0) # biClrUsed / biClrImportant

        for ($y = $h - 1; $y -ge 0; $y--) {        # bottom-up
            for ($x = 0; $x -lt $w; $x++) {
                $c = $Bitmap.GetPixel($x, $y)
                $bw.Write([byte]$c.B); $bw.Write([byte]$c.G)
                $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
            }
        }
        $bw.Write((New-Object byte[] ($andRowBytes * $h)))   # all-zero AND mask

        $bw.Flush()
        # Unary comma: returning a byte[] bare lets PowerShell unroll it into
        # thousands of individual bytes on the pipeline, and the caller then gets
        # an Object[] that BinaryWriter.Write silently declines to write.
        return ,$ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }
}

function ConvertTo-Png {
    param([System.Drawing.Bitmap]$Bitmap)
    $ms = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$ms.ToArray()
    } finally { $ms.Dispose() }
}

# --- Assemble the container ----------------------------------------------------
$payloads = @()
foreach ($size in $Sizes) {
    $bmp = New-DiscBitmap -Size $size
    try {
        # PNG-compressed entries are the standard for 256; the smaller frames stay
        # as DIBs for maximum compatibility with older icon consumers.
        $bytes = if ($size -ge 256) { [byte[]](ConvertTo-Png -Bitmap $bmp) } else { [byte[]](ConvertTo-IcoDib -Bitmap $bmp) }
        $payloads += [pscustomobject]@{ Size = $size; Bytes = $bytes }
    } finally { $bmp.Dispose() }
}

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
try {
    $bw.Write([uint16]0)                  # reserved
    $bw.Write([uint16]1)                  # type 1 = icon
    $bw.Write([uint16]$payloads.Count)

    $offset = 6 + (16 * $payloads.Count)  # ICONDIR + all ICONDIRENTRYs
    foreach ($p in $payloads) {
        $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }   # 0 means 256
        $bw.Write([byte]$dim)             # bWidth
        $bw.Write([byte]$dim)             # bHeight
        $bw.Write([byte]0)                # bColorCount - 0 for >8bpp
        $bw.Write([byte]0)                # bReserved
        $bw.Write([uint16]1)              # wPlanes
        $bw.Write([uint16]32)             # wBitCount
        $bw.Write([uint32]$p.Bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $p.Bytes.Length
    }
    foreach ($p in $payloads) { $bw.Write([byte[]]$p.Bytes) }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
} finally { $bw.Dispose(); $ms.Dispose() }

$sizeList = ($Sizes -join ', ')
Write-Host "  Wrote $OutFile ($sizeList) - $([math]::Round((Get-Item $OutFile).Length / 1KB, 1)) KB" -ForegroundColor Green

# Round-trip it through the icon loader so a malformed container fails HERE,
# loudly, rather than as an opaque csc error at build time.
$icon = New-Object System.Drawing.Icon($OutFile)
try { Write-Host "  Verified: loads as an Icon, default frame $($icon.Width)x$($icon.Height)" -ForegroundColor Green }
finally { $icon.Dispose() }
