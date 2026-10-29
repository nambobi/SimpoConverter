<#
.SYNOPSIS
    Converts PDF pages to PNG, JPG, TIFF or BMP images.

.DESCRIPTION
    SimpoConverter for Windows. Pages are rendered with the Windows.Data.Pdf API
    and saved with System.Drawing, so no other software is required.
    Requires Windows PowerShell 5.1 on Windows 10 or 11.

    Pages that already have an image are skipped, so an interrupted run can be
    continued by running the same command again.

    Commands: simpoconv update | version | help | uninstall

.PARAMETER Inputs
    PDF files or folders that contain PDF files. Without inputs, guided mode starts.

.PARAMETER Format
    Image format: png, jpg, tiff or bmp. Default: png.

.PARAMETER Dpi
    Resolution in dots per inch, 10-1200. Default: 150.

.PARAMETER Pages
    Pages to convert, for example 1-3,5,10-. Default: all pages.

.PARAMETER Output
    Output folder. Default: a folder named <pdf name>_images next to each PDF.

.PARAMETER Quality
    JPG quality, 1-100. Default: 90.

.PARAMETER Gray
    Save grayscale images.

.PARAMETER Password
    Password for protected PDF files. If omitted, the password is requested.

.PARAMETER Recurse
    Include sub-folders when a folder is given.

.PARAMETER Overwrite
    Convert pages again even if the image exists.

.PARAMETER Open
    Open the output folder when finished.

.EXAMPLE
    simpoconv "report.pdf" -Format jpg -Dpi 300 -Pages 1-3,7

.EXAMPLE
    simpoconv "D:\Scans" -Recurse -Output "D:\Scans\images"

.LINK
    https://github.com/nambobi/SimpoConverter
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool that writes coloured output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'The password is passed from cmd.exe, which cannot pass a SecureString.')]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Inputs,
    [Alias('f')][string]$Format = 'png',
    [Alias('d')][int]$Dpi = 150,
    [Alias('p')][string]$Pages,
    [Alias('o')][string]$Output,
    [Alias('q')][int]$Quality = 90,
    [Alias('g')][switch]$Gray,
    [string]$Password,
    [Alias('r')][switch]$Recurse,
    [switch]$Overwrite,
    [switch]$Open,
    [Alias('h')][switch]$Help,
    [Alias('v', 'Version')][switch]$ShowVersion
)

$ErrorActionPreference = 'Stop'
$AppVersion = '1.0'
$RepoRaw    = 'https://raw.githubusercontent.com/nambobi/SimpoConverter/main'
$RepoPage   = 'https://github.com/nambobi/SimpoConverter'

$UserHome = [Environment]::GetFolderPath('UserProfile')
if (-not $UserHome) { $UserHome = $HOME }
$StateDir   = Join-Path $UserHome '.simpoconverter'
$InstallDir = $null
if ($env:LOCALAPPDATA) { $InstallDir = Join-Path $env:LOCALAPPDATA 'SimpoConverter' }

# The progress bar slows down Invoke-WebRequest in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }  # TLS 1.2
catch { Write-Verbose 'TLS 1.2 could not be enabled.' }

# Supported output formats
$Formats = @{
    'png'  = @{ Name = 'PNG';  Ext = '.png';  Mime = 'image/png' }
    'jpg'  = @{ Name = 'JPEG'; Ext = '.jpg';  Mime = 'image/jpeg' }
    'jpeg' = @{ Name = 'JPEG'; Ext = '.jpg';  Mime = 'image/jpeg' }
    'tiff' = @{ Name = 'TIFF'; Ext = '.tiff'; Mime = 'image/tiff' }
    'tif'  = @{ Name = 'TIFF'; Ext = '.tiff'; Mime = 'image/tiff' }
    'bmp'  = @{ Name = 'BMP';  Ext = '.bmp';  Mime = 'image/bmp' }
}
$HResultWrongPassword = -2147023573   # 0x8007052B (ERROR_WRONG_PASSWORD)

# Console output ------------------------------------------------------------

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 20) { return $w } }
    catch { Write-Verbose 'Console width is not available.' }
    return 100
}
function Clear-ConsoleLine { Write-Host ("`r" + (' ' * ((Get-ConsoleWidth) - 1)) + "`r") -NoNewline }
function Write-Message([string]$Message, [string]$Color) {
    Clear-ConsoleLine
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
}
function Show-Progress([int]$Done, [int]$Total) {
    $width = 28
    $filled = [int][Math]::Floor($width * $Done / [Math]::Max(1, $Total))
    Write-Host ("`r    [" + ('#' * $filled) + ('-' * ($width - $filled)) + "] $Done/$Total") -NoNewline
}
function Read-Answer([string]$Prompt, [string]$Default) {
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    $answer = Read-Host "$Prompt$suffix"
    if (-not $answer) { return $Default }
    return $answer.Trim()
}
function Read-Password([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Input ---------------------------------------------------------------------

function Get-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# Returns an error message, or $null if the page list is valid.
function Test-PageList([string]$Spec) {
    if (-not $Spec -or $Spec.Trim() -eq 'all') { return $null }
    foreach ($part in (($Spec -replace '\s', '') -split ',')) {
        if (-not $part) { continue }
        if ($part -match '^(\d*)-(\d*)$') {
            if ($matches[1] -and [long]$matches[1] -lt 1) { return "'$part' is not a valid range" }
            if ($matches[1] -and $matches[2] -and [long]$matches[2] -lt [long]$matches[1]) {
                return "'$part' is not a valid range"
            }
        } elseif ($part -match '^\d+$') {
            if ([long]$part -lt 1) { return "'$part' is not a valid page number" }
        } else {
            return "'$part' is not a page number or range, e.g. 1-3,5,10-"
        }
    }
    return $null
}

# Converts a page list such as '1-3,5,10-' to sorted zero-based page indexes.
function Get-PageIndex([string]$Spec, [int]$Total) {
    $set = New-Object 'System.Collections.Generic.SortedSet[int]'
    if ($Total -lt 1) { return , ([int[]]@()) }
    if (-not $Spec -or $Spec.Trim() -eq 'all') { $Spec = '1-' }
    foreach ($part in (($Spec -replace '\s', '') -split ',')) {
        if (-not $part) { continue }
        if ($part -match '^(\d*)-(\d*)$') {
            $start = 1
            if ($matches[1]) { $start = [int]$matches[1] }
            $end = $Total
            if ($matches[2]) { $end = [int]$matches[2] }
        } else {
            $start = [int]$part
            $end = $start
        }
        if ($start -gt $Total) { continue }
        for ($i = $start; $i -le [Math]::Min($end, $Total); $i++) { [void]$set.Add($i - 1) }
    }
    return , ([int[]]@($set))
}

# Splits paths that were dragged into the console. Paths are separated by
# spaces and quoted if they contain spaces.
function Split-DroppedPath([string]$Text) {
    $value = "$Text".Trim()
    if (-not $value) { return , @() }
    $single = $value.Trim('"').Trim("'")
    if (Test-Path -LiteralPath $single) { return , @($single) }
    $paths = @()
    foreach ($m in [regex]::Matches($value, '"([^"]+)"|''([^'']+)''|(\S+)')) {
        $item = $m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value
        # PowerShell inserts a dragged file as: & 'C:\path\file.pdf'
        if ($item -and $item -ne '&') { $paths += $item }
    }
    return , $paths
}

# Returns the full paths of the PDF files in the given files and folders.
function Find-PdfFile([string[]]$Items, [bool]$IncludeSubfolders) {
    $found = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in $Items) {
        $path = "$item".Trim().Trim('"').Trim("'")
        if (-not $path) { continue }
        if (Test-Path -LiteralPath $path -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $path -File -Recurse:$IncludeSubfolders -ErrorAction SilentlyContinue |
                       Where-Object { $_.Extension -ieq '.pdf' } | Sort-Object FullName)
            if ($files.Count -eq 0) { Write-Message "Error: no PDF files in folder: $path" Yellow }
        } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            $files = @(Get-Item -LiteralPath $path)
        } else {
            Write-Message "Error: not found: $path" Red
            continue
        }
        foreach ($file in $files) {
            $key = $file.FullName.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $found.Add($file.FullName)
            }
        }
    }
    return , $found.ToArray()
}

# Returns the file name prefix for each PDF's images. Images are named after
# their PDF. If all images go to one output folder and two PDFs have the same
# name, the parent folder name is added to the prefix.
function Get-ImagePrefix([string[]]$PdfPaths, [bool]$SharedFolder) {
    $names = @($PdfPaths | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    if (-not $SharedFolder) { return , $names }
    $count = @{}
    foreach ($name in $names) {
        $key = $name.ToLowerInvariant()
        $count[$key] = 1 + [int]$count[$key]
    }
    $used = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        $parent = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($PdfPaths[$i]))
        if ($count[$name.ToLowerInvariant()] -gt 1 -and $parent) { $name = "${parent}_$name" }
        $candidate = $name
        $n = 2
        while ($used.ContainsKey($candidate.ToLowerInvariant())) {
            $candidate = "${name}_$n"
            $n++
        }
        $used[$candidate.ToLowerInvariant()] = $true
        $names[$i] = $candidate
    }
    return , $names
}

# PDF rendering -------------------------------------------------------------

function Initialize-PdfApi {
    if ($script:PdfApiReady) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        throw 'This script uses Windows Runtime types and must run in Windows PowerShell 5.1 (powershell.exe). The simpoconv command starts it that way.'
    }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        Add-Type -AssemblyName System.Drawing
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
    } catch {
        throw "The Windows.Data.Pdf API is not available. SimpoConverter requires Windows 10 or 11. ($($_.Exception.Message))"
    }
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $script:AsTaskOperation = $methods | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $script:AsTaskAction = $methods | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    } | Select-Object -First 1
    $script:ImageEncoders = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()
    $script:PdfApiReady = $true
}
function Wait-AsyncOperation($Operation, [Type]$ResultType) {
    $task = $script:AsTaskOperation.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    return $task.Result
}
function Wait-AsyncAction($Action) {
    $task = $script:AsTaskAction.Invoke($null, @($Action))
    [void]$task.Wait(-1)
}
function Get-InnermostException($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e
}
function Test-WrongPassword($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e.HResult -eq $HResultWrongPassword) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Opens a PDF and asks for the password if required (up to three times).
function Open-PdfDocument([string]$Path, [string]$PdfPassword, [bool]$AskPassword) {
    $file = Wait-AsyncOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $attempts = 0
    while ($true) {
        try {
            if ($PdfPassword) { $operation = [Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file, $PdfPassword) }
            else { $operation = [Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file) }
            return (Wait-AsyncOperation $operation ([Windows.Data.Pdf.PdfDocument]))
        } catch {
            if (-not (Test-WrongPassword $_)) { throw }
            if (-not $AskPassword -or $attempts -ge 3) { throw 'WRONG_PASSWORD' }
            $attempts++
            $label = 'Password'
            if ($PdfPassword) { $label = 'Wrong password, try again' }
            $PdfPassword = Read-Password ("    $label for " + [IO.Path]::GetFileName($Path))
        }
    }
}

# Copies the rendered PNG from the Windows Runtime stream to a MemoryStream.
function Read-RenderedPage($Stream) {
    $memory = New-Object System.IO.MemoryStream
    try {
        [void]$Stream.Seek(0)
        $netStream = [System.IO.WindowsRuntimeStreamExtensions]::AsStream($Stream)
        try { $netStream.CopyTo($memory) } finally { $netStream.Dispose() }
    } catch {
        # Fallback: read the bytes with a DataReader.
        $memory.SetLength(0)
        $size = [uint32]$Stream.Size
        $reader = [Windows.Storage.Streams.DataReader]::new($Stream.GetInputStreamAt(0))
        try {
            [void](Wait-AsyncOperation ($reader.LoadAsync($size)) ([uint32]))
            $bytes = New-Object byte[] $size
            $reader.ReadBytes($bytes)
            $memory.Write($bytes, 0, $bytes.Length)
        } finally { $reader.Dispose() }
    }
    if ($memory.Length -eq 0) { throw 'the rendered page is empty' }
    $memory.Position = 0
    return $memory
}
function ConvertTo-Grayscale([System.Drawing.Image]$Source) {
    $bitmap = New-Object System.Drawing.Bitmap $Source.Width, $Source.Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $bitmap.SetResolution($Source.HorizontalResolution, $Source.VerticalResolution)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    try {
        # ITU-R BT.601 luma weights
        $matrix = [single[][]]@(
            [single[]]@(0.299, 0.299, 0.299, 0, 0),
            [single[]]@(0.587, 0.587, 0.587, 0, 0),
            [single[]]@(0.114, 0.114, 0.114, 0, 0),
            [single[]]@(0, 0, 0, 1, 0),
            [single[]]@(0, 0, 0, 0, 1))
        $attributes.SetColorMatrix([System.Drawing.Imaging.ColorMatrix]::new($matrix))
        $rect = New-Object System.Drawing.Rectangle 0, 0, $Source.Width, $Source.Height
        $graphics.DrawImage($Source, $rect, 0, 0, $Source.Width, $Source.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    } finally {
        $attributes.Dispose()
        $graphics.Dispose()
    }
    return $bitmap
}
function Write-ImageFile([System.Drawing.Image]$Image, [string]$Path, $ImageFormat, [int]$JpegQuality) {
    $codec = $script:ImageEncoders | Where-Object { $_.MimeType -eq $ImageFormat.Mime } | Select-Object -First 1
    $parameters = $null
    if ($ImageFormat.Name -eq 'JPEG') {
        $parameters = New-Object System.Drawing.Imaging.EncoderParameters 1
        $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
            [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
    } elseif ($ImageFormat.Name -eq 'TIFF') {
        $parameters = New-Object System.Drawing.Imaging.EncoderParameters 1
        $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
            [System.Drawing.Imaging.Encoder]::Compression, [long][System.Drawing.Imaging.EncoderValue]::CompressionLZW)
    }
    $file = [IO.File]::Create($Path)
    try {
        $Image.Save($file, $codec, $parameters)
        $file.Flush($true)
    } finally {
        $file.Dispose()
        if ($parameters) { $parameters.Dispose() }
    }
}

# Writes the page to <target>.part, then renames it to <target>. An interrupted
# write leaves only the .part file, so a partial image is never saved under the
# final name.
function Save-PdfPage($Document, [int]$Index, [string]$Target, $ImageFormat, $Settings) {
    $part = "$Target.part"
    $page = $Document.GetPage([uint32]$Index)
    $stream = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
    $memory = $null
    $image = $null
    $grayImage = $null
    $finished = $false
    try {
        # PdfPage.Size is in device-independent pixels (1/96 inch).
        $scale = $Settings.Dpi / 96.0
        $options = [Windows.Data.Pdf.PdfPageRenderOptions]::new()
        $options.DestinationWidth  = [uint32][Math]::Max(1, [Math]::Round($page.Size.Width * $scale))
        $options.DestinationHeight = [uint32][Math]::Max(1, [Math]::Round($page.Size.Height * $scale))
        Wait-AsyncAction ($page.RenderToStreamAsync($stream, $options))   # PNG by default
        $memory = Read-RenderedPage $stream
        if ($ImageFormat.Name -eq 'PNG' -and -not $Settings.Gray) {
            $file = [IO.File]::Create($part)
            try {
                $memory.CopyTo($file)
                $file.Flush($true)
            } finally { $file.Dispose() }
        } else {
            $image = [System.Drawing.Image]::FromStream($memory)
            $toSave = $image
            if ($Settings.Gray) {
                $grayImage = ConvertTo-Grayscale $image
                $toSave = $grayImage
            }
            Write-ImageFile -Image $toSave -Path $part -ImageFormat $ImageFormat -JpegQuality $Settings.Quality
        }
        # .NET file methods treat the path literally, including [ and ].
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($part, $Target, $null) }
        else { [IO.File]::Move($part, $Target) }
        $finished = $true
    } finally {
        if ($grayImage) { $grayImage.Dispose() }
        if ($image) { $image.Dispose() }
        if ($memory) { $memory.Dispose() }
        $stream.Dispose()
        $page.Dispose()
        if (-not $finished) {
            try { [IO.File]::Delete($part) } catch { Write-Verbose "Cannot delete $part" }
        }
    }
}

# Conversion ----------------------------------------------------------------

# Converts one PDF. Returns the output folder, or $null if the file was skipped.
function Convert-PdfFile([string]$PdfPath, [string]$Prefix, $ImageFormat, $Settings, $Stats, [bool]$AskPassword) {
    try {
        $document = Open-PdfDocument -Path $PdfPath -PdfPassword $Settings.Password -AskPassword $AskPassword
    } catch {
        if ("$($_.Exception.Message)" -eq 'WRONG_PASSWORD') {
            if ($Settings.Password) { Write-Message '    Error: wrong password. Skipped.' Red }
            else { Write-Message '    Error: the file is password protected (use -Password). Skipped.' Red }
        } else {
            $reason = (Get-InnermostException $_).Message.Trim().TrimEnd('.')
            Write-Message "    Error: cannot open the file: $reason. Skipped." Red
        }
        $Stats.FailedPdfs++
        return $null
    }

    $total = [int]$document.PageCount
    $indexes = Get-PageIndex $Settings.Pages $total
    if ($indexes.Count -eq 0) {
        Write-Message "    Error: no pages in '$($Settings.Pages)' ($total in file). Skipped." Red
        $Stats.FailedPdfs++
        return $null
    }

    if ($Settings.Output) {
        $outDir = Get-FullPath $Settings.Output
    } else {
        $name = '{0}_images' -f [IO.Path]::GetFileNameWithoutExtension($PdfPath)
        $outDir = [IO.Path]::Combine([IO.Path]::GetDirectoryName($PdfPath), $name)
    }
    try {
        [void][IO.Directory]::CreateDirectory($outDir)
    } catch {
        Write-Message "    Error: cannot create folder ${outDir}: $((Get-InnermostException $_).Message) Skipped." Red
        $Stats.FailedPdfs++
        return $null
    }

    $pad = [Math]::Max(3, "$total".Length)
    Write-Message "    $total pages, converting $($indexes.Count) to $outDir"
    $n = 0
    foreach ($index in $indexes) {
        $n++
        $fileName = '{0}_page_{1}{2}' -f $Prefix, "$($index + 1)".PadLeft($pad, '0'), $ImageFormat.Ext
        $target = [IO.Path]::Combine($outDir, $fileName)
        if (-not $Settings.Overwrite -and [IO.File]::Exists($target) -and (New-Object IO.FileInfo $target).Length -gt 0) {
            $Stats.Skipped++
            Show-Progress $n $indexes.Count
            continue
        }
        try {
            Save-PdfPage -Document $document -Index $index -Target $target -ImageFormat $ImageFormat -Settings $Settings
            $Stats.Saved++
        } catch {
            Write-Host ''
            Write-Message ('    Error: page {0} failed: {1}' -f ($index + 1), (Get-InnermostException $_).Message.Trim()) Red
            $Stats.FailedPages++
        }
        Show-Progress $n $indexes.Count
    }
    Write-Host ''
    return $outDir
}

# Converts all inputs. Returns $true if every page was converted.
function Invoke-Conversion([string[]]$Items, $Settings, [bool]$AskPassword, [bool]$OpenFolder) {
    $imageFormat = $Formats[$Settings.Format]
    $pdfPaths = Find-PdfFile $Items $Settings.Recurse
    if ($pdfPaths.Count -eq 0) {
        Write-Message 'No PDF files to convert.' Yellow
        return $false
    }
    Initialize-PdfApi

    $stats = @{ Saved = 0; Skipped = 0; FailedPages = 0; FailedPdfs = 0 }
    $prefixes = Get-ImagePrefix $pdfPaths ([bool]$Settings.Output)
    $folders = New-Object System.Collections.Generic.List[string]
    $imageType = $imageFormat.Name
    if ($Settings.Gray) { $imageType += ' grayscale' }
    Write-Message ("Converting {0} PDF file(s) to {1} at {2} dpi`n" -f $pdfPaths.Count, $imageType, $Settings.Dpi) Cyan
    $started = Get-Date
    $script:Busy = $true
    for ($i = 0; $i -lt $pdfPaths.Count; $i++) {
        Write-Message ('[{0}/{1}] {2}' -f ($i + 1), $pdfPaths.Count, [IO.Path]::GetFileName($pdfPaths[$i]))
        $folder = Convert-PdfFile -PdfPath $pdfPaths[$i] -Prefix $prefixes[$i] -ImageFormat $imageFormat `
            -Settings $Settings -Stats $stats -AskPassword $AskPassword
        if ($folder -and -not $folders.Contains($folder)) { $folders.Add($folder) }
    }
    $script:Busy = $false

    $seconds = ((Get-Date) - $started).TotalSeconds
    $summary = "`nDone in {0:N1} s. Saved: {1}" -f $seconds, $stats.Saved
    if ($stats.Skipped)     { $summary += ". Skipped (already exist): $($stats.Skipped)" }
    if ($stats.FailedPages) { $summary += ". Failed pages: $($stats.FailedPages)" }
    if ($stats.FailedPdfs)  { $summary += ". Skipped files: $($stats.FailedPdfs)" }
    $ok = ($stats.FailedPages -eq 0 -and $stats.FailedPdfs -eq 0)
    $color = 'Green'
    if (-not $ok) { $color = 'Yellow' }
    Write-Message "$summary." $color
    if ($folders.Count -eq 1) { Write-Message "Output folder: $($folders[0])" }
    if ($OpenFolder) {
        foreach ($folder in $folders) {
            try { Invoke-Item -LiteralPath $folder } catch { Write-Verbose "Cannot open $folder" }
        }
    }
    return $ok
}

# Asks for the input and settings, converts, and repeats if requested.
function Invoke-GuidedMode($Settings) {
    while ($true) {
        Write-Host "`nDrag a PDF file or folder here and press Enter:"
        Write-Host '> ' -NoNewline
        $items = Split-DroppedPath (Read-Host)
        if ($items.Count -eq 0) {
            Write-Message 'No file given.' Yellow
            return $true
        }
        while ($true) {
            $answer = (Read-Answer 'Format (png, jpg, tiff, bmp)' $Settings.Format).ToLowerInvariant()
            if ($Formats.ContainsKey($answer)) { $Settings.Format = $answer; break }
            Write-Message '  Enter png, jpg, tiff or bmp.' Yellow
        }
        while ($true) {
            $answer = Read-Answer 'Resolution in dpi (150 for screen, 300 for print)' "$($Settings.Dpi)"
            if ($answer -match '^\d+$' -and [int]$answer -ge 10 -and [int]$answer -le 1200) { $Settings.Dpi = [int]$answer; break }
            Write-Message '  Enter a number from 10 to 1200.' Yellow
        }
        while ($true) {
            $defaultPages = 'all'
            if ($Settings.Pages) { $defaultPages = $Settings.Pages }
            $answer = Read-Answer 'Pages, e.g. 1-3,5' $defaultPages
            $problem = Test-PageList $answer
            if (-not $problem) { $Settings.Pages = $answer; break }
            Write-Message "  $problem" Yellow
        }
        Write-Host ''
        [void](Invoke-Conversion -Items $items -Settings $Settings -AskPassword $true -OpenFolder $true)
        if ((Read-Answer "`nConvert another file? (y/n)" 'n') -notlike 'y*') { break }
    }
    return $true
}

# Updates -------------------------------------------------------------------

function Get-LatestVersion([int]$TimeoutSec) {
    try {
        $response = Invoke-WebRequest -Uri "$RepoRaw/VERSION" -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'Cache-Control' = 'no-cache' }
        $value = ([string]$response.Content).Trim()
        if ($value -match '^\d+(\.\d+){1,3}$') { return $value }
    } catch { Write-Verbose "Version check failed: $($_.Exception.Message)" }
    return $null
}
function Test-NewerVersion([string]$Candidate, [string]$Current) {
    try { return ([version]$Candidate -gt [version]$Current) }
    catch { return $false }
}
function Save-UpdateCheck {
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $StateDir 'last_update_check') -Value (Get-Date -Format o)
    } catch { Write-Verbose 'Cannot save the update check time.' }
}

# Checks for a new version at most once a day, with a 3-second timeout.
function Show-UpdateNotice {
    try {
        $stamp = Join-Path $StateDir 'last_update_check'
        if ((Test-Path -LiteralPath $stamp) -and ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalHours -lt 24) { return }
        Save-UpdateCheck
        $latest = Get-LatestVersion 3
        if ($latest -and (Test-NewerVersion $latest $AppVersion)) {
            Write-Message "Version $latest is available (installed: $AppVersion)." Yellow
            Write-Message 'Run: simpoconv update' Yellow
        }
    } catch { Write-Verbose 'Update check skipped.' }
}
function Invoke-Update {
    Write-Message 'Checking for updates...' DarkGray
    $latest = Get-LatestVersion 15
    if (-not $latest) {
        Write-Message "Error: cannot reach $RepoPage. Check the internet connection." Red
        return $false
    }
    if (-not (Test-NewerVersion $latest $AppVersion)) {
        Write-Message "SimpoConverter $AppVersion is the latest version." Green
        return $true
    }
    $target = $PSCommandPath
    $newFile = "$target.new"
    try {
        Invoke-WebRequest -Uri "$RepoRaw/simpoconv.ps1" -UseBasicParsing -OutFile $newFile -TimeoutSec 60
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($newFile, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0 -or -not (Select-String -LiteralPath $newFile -Pattern 'SimpoConverter' -Quiet)) {
            throw 'the downloaded file is not valid'
        }
        Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
        Move-Item -LiteralPath $newFile -Destination $target -Force
    } catch {
        Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
        Write-Message "Update failed: $($_.Exception.Message). The installed version was not changed." Red
        return $false
    }
    Write-Message "Updated SimpoConverter $AppVersion to $latest." Green
    try {
        $lines = (Invoke-WebRequest -Uri "$RepoRaw/CHANGELOG.md" -UseBasicParsing -TimeoutSec 15).Content -split "`n"
        Write-Message "`nChanges:" Cyan
        $sections = 0
        foreach ($line in $lines) {
            if ($line -match '^## ') {
                $sections++
                if ($sections -gt 1) { break }
            }
            if ($sections -ge 1 -and $line.Trim()) { Write-Host "  $($line.TrimEnd())" }
        }
    } catch { Write-Verbose 'Cannot download the changelog.' }
    Save-UpdateCheck
    return $true
}
function Invoke-Uninstall {
    if (-not $InstallDir -or -not (Test-Path -LiteralPath $InstallDir)) {
        Write-Message 'SimpoConverter is not installed for this user.' Yellow
        return
    }
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        $oldPath = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $newPath = (@($oldPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $InstallDir.TrimEnd('\') })) -join ';'
        $key.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.Close()
        # Setting a user variable broadcasts WM_SETTINGCHANGE, so new terminals see the new PATH.
        [Environment]::SetEnvironmentVariable('SIMPOCONV_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('SIMPOCONV_REFRESH', $null, 'User')
    } catch { Write-Message "Cannot update PATH: $($_.Exception.Message)" Yellow }
    # The folder is in use by this process, so it is deleted after a short delay.
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Message 'SimpoConverter has been uninstalled.' Green
}

# Main ----------------------------------------------------------------------

function Show-Help {
    Write-Host @"
SimpoConverter $AppVersion - convert PDF pages to PNG, JPG, TIFF or BMP images

Usage:
  simpoconv                         guided mode
  simpoconv "file.pdf" [...]        convert one or more PDF files
  simpoconv "D:\Scans"              convert all PDF files in a folder

Options:
  -f, -Format png|jpg|tiff|bmp      image format (default: png)
  -d, -Dpi <10-1200>                resolution in dots per inch (default: 150)
  -p, -Pages <list>                 pages to convert, e.g. 1-3,5,10- (default: all)
  -o, -Output <folder>              output folder (default: <pdf name>_images next to each PDF)
  -q, -Quality <1-100>              JPG quality (default: 90)
  -g, -Gray                         save grayscale images
      -Password <password>          password for protected PDF files
  -r, -Recurse                      include sub-folders
      -Overwrite                    convert pages again even if the image exists
      -Open                         open the output folder when finished

Commands:
  simpoconv update                  install the latest version from GitHub
  simpoconv version                 show the installed version
  simpoconv uninstall               remove SimpoConverter

Pages that already have an image are skipped, so an interrupted run can be
continued by running the same command again.

$RepoPage
"@
}

$Inputs = @($Inputs | Where-Object { "$_".Trim() })
if ($Help) { Show-Help; exit 0 }
if ($ShowVersion) { Write-Host "SimpoConverter $AppVersion"; exit 0 }
if ($Inputs.Count -eq 1 -and -not (Test-Path -LiteralPath $Inputs[0])) {
    switch -Regex ($Inputs[0]) {
        '^(help|-h|--help|/\?|-\?)$' { Show-Help; exit 0 }
        '^(version|-v|--version)$'   { Write-Host "SimpoConverter $AppVersion"; exit 0 }
        '^update$'                   { if (Invoke-Update) { exit 0 } else { exit 1 } }
        '^uninstall$'                { Invoke-Uninstall; exit 0 }
    }
}
$unknown = @($Inputs | Where-Object { $_ -like '--*' })
if ($unknown.Count -gt 0) {
    Write-Message "Error: unknown option $($unknown[0]). Options use one dash, e.g. -Format jpg or -f jpg." Red
    exit 2
}
$Format = "$Format".ToLowerInvariant()
if ($Format -eq 'webp') { Write-Message 'Error: WEBP output is not supported on Windows. Use png, jpg, tiff or bmp.' Red; exit 2 }
if (-not $Formats.ContainsKey($Format)) { Write-Message "Error: unknown format '$Format'. Use png, jpg, tiff or bmp." Red; exit 2 }
if ($Dpi -lt 10 -or $Dpi -gt 1200) { Write-Message 'Error: -Dpi must be between 10 and 1200.' Red; exit 2 }
if ($Quality -lt 1 -or $Quality -gt 100) { Write-Message 'Error: -Quality must be between 1 and 100.' Red; exit 2 }
$pageError = Test-PageList $Pages
if ($pageError) { Write-Message "Error: -Pages: $pageError" Red; exit 2 }

$settings = [pscustomobject]@{
    Format    = $Format
    Dpi       = $Dpi
    Pages     = $Pages
    Output    = $Output
    Quality   = $Quality
    Gray      = $Gray.IsPresent
    Password  = $Password
    Recurse   = $Recurse.IsPresent
    Overwrite = $Overwrite.IsPresent
}

$script:Busy = $false
Write-Message "SimpoConverter $AppVersion" Cyan
Show-UpdateNotice
$ok = $false
try {
    if ($Inputs.Count -eq 0) {
        $ok = Invoke-GuidedMode $settings
    } else {
        $askPassword = (-not $Password) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        $ok = Invoke-Conversion -Items $Inputs -Settings $settings -AskPassword $askPassword -OpenFolder $Open.IsPresent
    }
} catch {
    Write-Message "Error: $((Get-InnermostException $_).Message)" Red
    $ok = $false
} finally {
    if ($script:Busy) { Write-Message "`nInterrupted. Run the same command again to convert the rest." Yellow }
}
if ($ok) { exit 0 } else { exit 1 }
