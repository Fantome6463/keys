<#
.SYNOPSIS
  Собирает Keys.exe - запускатор окна управления. Использует компилятор C#, встроенный
  в Windows (ничего скачивать не нужно). Собирается один раз; окно обновляется вместе с кодом.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot

$csc = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "Не найден компилятор C# (.NET Framework 4). Он входит в Windows 10/11 и Windows Server." }

# Иконка: синяя плитка с белым ключом, PNG-кадры разных размеров.
function New-IconFrame([int]$Size) {
    $bitmap = New-Object Drawing.Bitmap($Size, $Size)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = "AntiAlias"
    $g.Clear([Drawing.Color]::Transparent)
    $k = $Size / 32.0
    $radius = [Math]::Max(2, [int](8 * $k))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2; $m = $Size - 1
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($m - $d, 0, $d, $d, 270, 90)
    $path.AddArc($m - $d, $m - $d, $d, $d, 0, 90); $path.AddArc(0, $m - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $fill = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle(0, 0, $Size, $Size)),
        [Drawing.Color]::FromArgb(37, 99, 235), [Drawing.Color]::FromArgb(13, 148, 136), 45.0)
    $g.FillPath($fill, $path)
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, [Math]::Max(1.5, 3 * $k))
    $pen.StartCap = "Round"; $pen.EndCap = "Round"
    # головка ключа - кольцо, стержень и две бородки
    $g.DrawEllipse($pen, (5 * $k), (10 * $k), (11 * $k), (11 * $k))
    $g.DrawLine($pen, (16 * $k), (15.5 * $k), (27 * $k), (15.5 * $k))
    $g.DrawLine($pen, (23 * $k), (15.5 * $k), (23 * $k), (20 * $k))
    $g.DrawLine($pen, (27 * $k), (15.5 * $k), (27 * $k), (21 * $k))
    $g.Dispose()
    $stream = New-Object IO.MemoryStream
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    return , $stream.ToArray()
}

$sizes = @(16, 32, 48, 64, 256)
$frames = @()
foreach ($size in $sizes) { $frames += , (New-IconFrame $size) }
$icoPath = Join-Path $PSScriptRoot "app.ico"
$file = [IO.File]::Create($icoPath)
$writer = New-Object IO.BinaryWriter($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($frame in $frames) { $writer.Write($frame) }
$writer.Dispose()
$file.Dispose()

$exe = Join-Path $root "Keys.exe"
& $csc /nologo /target:winexe /codepage:65001 "/out:$exe" "/win32icon:$icoPath" "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')" /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot "launcher.cs")
if ($LASTEXITCODE -ne 0) { throw "Не удалось собрать Keys.exe." }
Write-Host "Готово: $exe" -ForegroundColor Green
