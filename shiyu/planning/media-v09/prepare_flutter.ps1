$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspaceRoot = [IO.Directory]::GetParent($expectedProject).FullName
if ([IO.Path]::GetFullPath((Get-Location).Path) -ne $workspaceRoot) {throw 'Run this script from the original workspace root'}
$toolRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot 'shiyu/.toolchains'))
if (-not $toolRoot.StartsWith($workspaceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {throw 'Tool root outside workspace'}
$meta = Get-Content 'shiyu/planning/media-v09/flutter-release-verified.json' -Raw | ConvertFrom-Json
if ($meta.version -ne '3.50.0' -or $meta.hash -ne 'ab2912035e160d9cad6306df307576da6128ebdb' -or $meta.sha256 -notmatch '^[a-f0-9]{64}$') {throw 'Unexpected release identity'}
if ($meta.sizeBytes -gt 3GB -or $meta.archiveUrl -notlike 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/*') {throw 'Unexpected source or download size'}
$downloads = Join-Path $toolRoot 'downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
foreach ($ownedDir in @($toolRoot, $downloads)) {
    if ((Get-Item -LiteralPath $ownedDir).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Dedicated tool path is a reparse point; inspect before writing'}
}
$driveRoot = [IO.Path]::GetPathRoot($toolRoot)
if (([IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace -lt 12GB) {throw 'Insufficient free space for the dedicated 12 GiB allowance'}
$archive = Join-Path $downloads 'flutter_windows_3.50.0-stable.zip'
$partial = $archive + '.partial'
if (-not (Test-Path -LiteralPath $archive)) {
    Write-Output 'Downloading fixed official Flutter archive (1868535132 bytes); no installer/global environment changes.'
    & python 'shiyu/planning/media-v09/download_archive.py'
    if ($LASTEXITCODE -ne 0) {throw 'Download failed; partial/ranges retained, SDK not executed'}
    if ((Get-Item -LiteralPath $partial).Length -ne $meta.sizeBytes) {throw 'Download length mismatch'}
    $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $meta.sha256) {throw 'SHA256 mismatch; do not extract or execute'}
    Move-Item -LiteralPath $partial -Destination $archive
} else {
    if ((Get-Item -LiteralPath $archive).Length -ne $meta.sizeBytes -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $meta.sha256) {throw 'Cached archive identity mismatch'}
}
Write-Output 'Official archive length and SHA256 verified.'
$flutterRoot = Join-Path $toolRoot 'flutter'
$completeMarker = Join-Path $toolRoot 'flutter-extracted.json'
if (-not (Test-Path -LiteralPath $completeMarker)) {
    if (Test-Path -LiteralPath $flutterRoot) {throw 'Existing unmarked Flutter directory; inspect before retrying extraction'}
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        [long]$unpacked = 0
        foreach ($entry in $zip.Entries) {
            $normalized = $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $destination = [IO.Path]::GetFullPath((Join-Path $toolRoot $normalized))
            if (-not $destination.StartsWith($flutterRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $destination -ne $flutterRoot) {throw 'Archive entry outside dedicated Flutter directory'}
            $unpacked += $entry.Length
        }
        if ($unpacked + $meta.sizeBytes -gt 12GB) {throw 'Archive exceeds initial dedicated disk allowance'}
    } finally { $zip.Dispose() }
    Write-Output "Extracting verified archive; declared unpacked bytes: $unpacked"
    if (([IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace -lt ($unpacked + 2GB)) {throw 'Insufficient free space for extraction and reserve'}
    & tar.exe -xf $archive -C $toolRoot
    if ($LASTEXITCODE -ne 0) {throw 'Extraction failed; do not execute partial SDK'}
    [pscustomobject]@{version=$meta.version;commit=$meta.hash;archiveSha256=$meta.sha256;archiveBytes=$meta.sizeBytes;unpackedBytes=$unpacked;globalEnvironmentChanged=$false;deviceAccessed=$false} | ConvertTo-Json | Set-Content $completeMarker -Encoding utf8
}
$marker = Get-Content -LiteralPath $completeMarker -Raw | ConvertFrom-Json
if ($marker.version -ne $meta.version -or $marker.commit -ne $meta.hash -or $marker.archiveSha256 -ne $meta.sha256) {throw 'Extraction marker identity mismatch'}
foreach ($relativeBinary in @('bin/flutter.bat', 'bin/cache/dart-sdk/bin/dart.exe')) {
    $binary = Join-Path $flutterRoot $relativeBinary
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or (Get-Item -LiteralPath $binary).Length -eq 0) {throw 'Required SDK executable missing after extraction'}
}
$head = & git -C $flutterRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head.Trim() -ne $meta.hash) {throw 'Extracted Git revision mismatch'}
Write-Output ('SDK extracted and Git identity verified: ' + $head.Trim())
Get-Content $completeMarker -Raw
