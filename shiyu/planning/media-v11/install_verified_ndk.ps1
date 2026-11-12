# Reviewed preparation only: no downloads, licenses, package.xml generation, or devices.
[CmdletBinding()]
param(
    [string]$ToolchainsRoot = 'R:/shiyu/.toolchains',
    [string]$GoogleMetadata = 'R:/shiyu/planning/media-v10/android-repository-verified.json',
    [string]$VerifiedArchive = 'R:/shiyu/planning/media-v11/results/ndk-archive-verified.json'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$expectedRevision = '28.2.13676358'
$expectedRoot = 'android-ndk-r28c'
$expectedBytes = 748118221L
$expectedSha1 = '086bba43ff2f5eb0e387b15c8278bb4e0d89ba1d'
$expectedUrl = 'https://dl.google.com/android/repository/android-ndk-r28c-windows.zip'
$allowedRoots = @(
    'R:/shiyu/.toolchains',
    'C:/src/51/shiyu/.toolchains'
) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
$root = [IO.Path]::GetFullPath($ToolchainsRoot).TrimEnd('\', '/')
if ($root -notin $allowedRoots -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'Unexpected toolchain root.'
}
function Assert-OwnedPath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path outside owned toolchain root: $absolute"
    }
    # Reject junction/symlink descendants that could redirect writes outside root.
    $relative = $absolute.Substring($root.Length + 1)
    $cursor = $root
    foreach ($part in $relative.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse point within target path: $cursor"
            }
        }
    }
    return $absolute
}
function Get-Revision([string]$Text) {
    $matches = [regex]::Matches($Text, '(?m)^Pkg\.Revision\s*=\s*([^\r\n]+)')
    if ($matches.Count -ne 1) { throw 'Missing or duplicate Pkg.Revision.' }
    return $matches[0].Groups[1].Value.Trim()
}

$proofPath = [IO.Path]::GetFullPath($VerifiedArchive)
$allowedProofs = @(
    'R:/shiyu/planning/media-v11/results/ndk-archive-verified.json',
    'C:/src/51/shiyu/planning/media-v11/results/ndk-archive-verified.json'
) | ForEach-Object { [IO.Path]::GetFullPath($_) }
if ($proofPath -notin $allowedProofs) { throw 'Unexpected download verification receipt path.' }
$proof = [IO.File]::ReadAllText($proofPath) | ConvertFrom-Json
# Contract for the root-produced verification receipt; no fallback to unverified parts.
foreach ($key in @('archive', 'sizeBytes', 'officialAlgorithm', 'officialChecksumMatched', 'localSha256', 'localSha256IsOfficialPublishedValue', 'installed')) {
    if ($null -eq $proof.PSObject.Properties[$key]) { throw "Missing archive receipt field: $key" }
}
if ([long]$proof.sizeBytes -ne $expectedBytes -or $proof.archive -cne 'android-ndk-r28c-windows.zip' -or
    $proof.officialAlgorithm -ne 'sha1' -or $proof.officialChecksumMatched -ne $true -or
    $proof.localSha256IsOfficialPublishedValue -ne $false -or $proof.localSha256 -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'Verification receipt does not match the fixed official NDK.'
}
$metadataAllowed = @(
    'R:/shiyu/planning/media-v10/android-repository-verified.json',
    'C:/src/51/shiyu/planning/media-v10/android-repository-verified.json'
) | ForEach-Object { [IO.Path]::GetFullPath($_) }
$metadataPath = [IO.Path]::GetFullPath($GoogleMetadata)
if ($metadataPath -notin $metadataAllowed) { throw 'Unexpected official metadata snapshot path.' }
$metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
$packages = @($metadata.packages | Where-Object { $_.path -eq "ndk;$expectedRevision" })
if ($packages.Count -ne 1) { throw 'Missing unique NDK package in official metadata snapshot.' }
$archives = @($packages[0].archives | Where-Object { $_.hostOs -eq 'windows' })
if ($archives.Count -ne 1 -or $archives[0].checksumType -ne 'sha1' -or
    [long]$archives[0].sizeBytes -ne $expectedBytes -or $archives[0].checksum -ne $expectedSha1 -or
    $archives[0].url -ne $expectedUrl) { throw 'Official metadata mismatch.' }
$archivePath = Assert-OwnedPath (Join-Path $root ('downloads/' + $proof.archive))
$archive = Get-Item -LiteralPath $archivePath
if ($archive.PSIsContainer -or $archive.Length -ne $expectedBytes) { throw 'Archive size mismatch.' }
$actualSha1 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA1).Hash.ToLowerInvariant()
$actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha1 -ne $expectedSha1 -or $actualSha256 -ne $proof.localSha256.ToLowerInvariant()) {
    throw 'Archive hash mismatch; nothing extracted.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
$entryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$expandedBytes = 0L
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        $segments = $name.Split('/')
        $badSegments = @($segments | Where-Object { $_.TrimEnd(' ', '.') -cne $_ })
        if ($name -notlike "$expectedRoot/*" -or $name.Contains(':') -or
            $segments -contains '..' -or $segments -contains '.' -or
            $badSegments.Count -gt 0) {
            throw "Unsafe/unexpected ZIP path: $name"
        }
        # Windows junction/reparse flags or UNIX symlink mode cannot be extracted.
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixType -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)) {
            throw "Linked ZIP entry rejected: $name"
        }
        if (-not $entryNames.Add($name)) { throw "Duplicate ZIP path: $name" }
        $expandedBytes += $entry.Length
        if ($expandedBytes -gt 8GB) { throw 'Unexpected expanded NDK size exceeds staging guard.' }
    }
    $sourceEntry = $zip.GetEntry("$expectedRoot/source.properties")
    if ($null -eq $sourceEntry -or $sourceEntry.Length -gt 16384) { throw 'Invalid source.properties entry.' }
    $reader = [IO.StreamReader]::new($sourceEntry.Open())
    try { $sourceText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ((Get-Revision $sourceText) -ne $expectedRevision) { throw 'ZIP Pkg.Revision mismatch.' }
} finally { $zip.Dispose() }

$installParent = Assert-OwnedPath (Join-Path $root 'android-sdk/ndk')
$destination = Assert-OwnedPath (Join-Path $installParent $expectedRevision)
$destinationProperties = Assert-OwnedPath (Join-Path $destination 'source.properties')
if (Test-Path -LiteralPath $destinationProperties) {
    $installedRevision = Get-Revision ([IO.File]::ReadAllText($destinationProperties))
    throw "Existing NDK source.properties found ($installedRevision); refusing to overwrite installed NDK."
}
$ownedStaging = Assert-OwnedPath (Join-Path $root ('install-staging/ndk-' + [guid]::NewGuid().ToString('N')))
[void][IO.Directory]::CreateDirectory($ownedStaging)
[IO.File]::WriteAllText((Join-Path $ownedStaging 'OWNER.txt'), 'shiyu verified NDK installer staging; preserve on failure', $utf8)
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $ownedStaging)
$extracted = Assert-OwnedPath (Join-Path $ownedStaging $expectedRoot)
$extractedProperties = Assert-OwnedPath (Join-Path $extracted 'source.properties')
if ((Get-Revision ([IO.File]::ReadAllText($extractedProperties))) -ne $expectedRevision) {
    throw 'Extracted source.properties mismatch; staging retained.'
}
[void][IO.Directory]::CreateDirectory($installParent)
$retainedPlaceholder = $null
if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw 'NDK destination is not a directory.' }
    # Revalidate both absolute paths immediately before moving a failed placeholder.
    $destination = Assert-OwnedPath $destination
    $retainedPlaceholder = Assert-OwnedPath ($destination + '.failed-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath (Join-Path $destination 'source.properties')) { throw 'NDK appeared concurrently; refusing replacement.' }
    Move-Item -LiteralPath $destination -Destination $retainedPlaceholder
}
$extracted = Assert-OwnedPath $extracted
$destination = Assert-OwnedPath $destination
if (Test-Path -LiteralPath $destination) { throw 'Destination appeared concurrently; staging retained.' }
Move-Item -LiteralPath $extracted -Destination $destination
if ((Get-Revision ([IO.File]::ReadAllText((Join-Path $destination 'source.properties')))) -ne $expectedRevision) {
    throw 'Post-move revision verification failed.'
}
$receiptDirectory = Assert-OwnedPath (Join-Path $root 'results')
[void][IO.Directory]::CreateDirectory($receiptDirectory)
$receiptPath = Assert-OwnedPath (Join-Path $receiptDirectory ('ndk-manual-install-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json'))
$receipt = [ordered]@{
    installed_at_utc = [DateTime]::UtcNow.ToString('o')
    method = 'verified_official_standalone_zip_no_generated_package_xml'
    revision = $expectedRevision
    destination = $destination
    archive_path = $archivePath
    size_bytes = $expectedBytes
    official_sha1 = $actualSha1
    local_sha256 = $actualSha256
    source_url = $expectedUrl
    expanded_bytes = $expandedBytes
    retained_failed_placeholder = $retainedPlaceholder
    retained_staging = $ownedStaging
    sdkmanager_recognition = 'pending_separate_list_installed_check'
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 4), $utf8)
Write-Output ($receipt | ConvertTo-Json -Depth 4)
