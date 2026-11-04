# Draws Laurels' wreath icon (Media/LaurelsIcon.tga, used by the minimap
# button). Original art, drawn here so the addon ships nothing it doesn't own.
# Run from the addon root:
#   powershell -ExecutionPolicy Bypass -File tools\make_icon.ps1 -OutTga Media\LaurelsIcon.tga -OutPng icon.png -PreviewPng preview.png
# The preview shows it at minimap size; check it there, where detail is lost.

param([string]$OutTga, [string]$OutPng, [string]$PreviewPng)
Add-Type -AssemblyName System.Drawing

$S = 64
$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

$leaf    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 70, 180, 80))
$edge    = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 10, 45, 16)), 1.3
$stemPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 30, 105, 40)), 2.4

[double]$cx = 32; [double]$cy = 31; [double]$r = 21

# A branch follows an arc around (cx, cy). theta is math-convention degrees
# (y up); mirror = 1 draws the left branch, -1 the right.
function Point([double]$theta, [double]$mirror) {
    $a = $theta * [Math]::PI / 180
    return @(($cx + $mirror * $r * [Math]::Cos($a)), ($cy - $r * [Math]::Sin($a)))
}

function Draw-Branch([double]$mirror) {
    [double]$from = 262; [double]$to = 128   # bottom -> upper side
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -le 40; $i++) {
        $p = Point ($from + ($to - $from) * $i / 40) $mirror
        $pts.Add((New-Object System.Drawing.PointF ([float]$p[0]), ([float]$p[1])))
    }
    $g.DrawLines($stemPen, $pts.ToArray())

    $leaves = 7
    for ($i = 0; $i -lt $leaves; $i++) {
        [double]$t = ($i + 0.6) / $leaves
        [double]$theta = $from + ($to - $from) * $t
        $p = Point $theta $mirror
        $a = $theta * [Math]::PI / 180
        # Direction of travel (theta decreasing), in screen space.
        [double]$dx = $mirror * [Math]::Sin($a)
        [double]$dy = [Math]::Cos($a)
        [double]$heading = [Math]::Atan2($dy, $dx) * 180 / [Math]::PI
        [double]$len = 11.5 - 4.0 * $t        # leaves shrink toward the tip
        foreach ($side in @(1.0, -1.0)) {
            $state = $g.Save()
            $g.TranslateTransform([float]$p[0], [float]$p[1])
            $g.RotateTransform([float]($heading + $side * 40))
            $g.FillEllipse($leaf, [float]0, [float](-$len * 0.21), [float]$len, [float]($len * 0.42))
            $g.DrawEllipse($edge, [float]0, [float](-$len * 0.21), [float]$len, [float]($len * 0.42))
            $g.Restore($state)
        }
    }
}
Draw-Branch 1.0
Draw-Branch (-1.0)
$g.Dispose()

$bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)

# Preview: at minimap size on the minimap's dark fill, at 2x, and at 4x.
$pv = New-Object System.Drawing.Bitmap 220, 90
$pg = [System.Drawing.Graphics]::FromImage($pv)
$pg.Clear([System.Drawing.Color]::FromArgb(255, 60, 60, 60))
$pg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 12, 12, 14))
$pg.FillEllipse($dark, 6, 32, 24, 24)
$pg.DrawImage($bmp, 9, 35, 18, 18)
$pg.FillEllipse($dark, 40, 22, 44, 44)
$pg.DrawImage($bmp, 44, 26, 36, 36)
$pg.DrawImage($bmp, 120, 10, 72, 72)
$pg.Dispose()
$pv.Save($PreviewPng, [System.Drawing.Imaging.ImageFormat]::Png)

# Uncompressed 32-bit TGA, top-left origin, 8 alpha bits. Bitmap memory is
# already BGRA, which is TGA's byte order.
$rect = New-Object System.Drawing.Rectangle 0, 0, $S, $S
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bytes = New-Object byte[] ($S * $S * 4)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)
$header = [byte[]](0,0,2, 0,0,0,0,0, 0,0, 0,0, ($S -band 255),($S -shr 8), ($S -band 255),($S -shr 8), 32, 0x28)
$fs = [System.IO.File]::Create($OutTga)
$fs.Write($header, 0, $header.Length)
$fs.Write($bytes, 0, $bytes.Length)
$fs.Close()
$bmp.Dispose()
"wrote $OutTga ($((Get-Item $OutTga).Length) bytes)"
