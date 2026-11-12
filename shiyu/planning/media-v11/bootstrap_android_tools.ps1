param([switch]$AcceptAndroidSdkLicense)
if (-not $AcceptAndroidSdkLicense) { throw "Review the Google Android SDK license, then explicitly pass -AcceptAndroidSdkLicense." }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$physicalProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$physicalWorkspace = [IO.Directory]::GetParent($physicalProject).FullName
$physicalTools = Join-Path $physicalProject '.toolchains'
$baselinePath = Join-Path $PSScriptRoot 'android-prep-baseline.json'
if (-not (Test-Path $baselinePath)) {
    $bytes = [long](Get-ChildItem -LiteralPath $physicalTools -File -Recurse | Measure-Object Length -Sum).Sum
    [pscustomobject]@{userApprovedSdkLicense=$true;date='2026-11-12';baselineToolDirectoryBytes=$bytes;additionalDiskBudgetBytes=12GB;newDownloadBudgetBytes=3GB}|ConvertTo-Json|Set-Content $baselinePath -Encoding utf8
}
if (([IO.DriveInfo]::new([IO.Path]::GetPathRoot($physicalTools))).AvailableFreeSpace -lt 12GB) {throw 'Insufficient free space for approved additional allowance'}
Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices; public static class AndroidWorkspaceDevice { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint QueryDosDevice(string name, StringBuilder target, int size); }'
$buffer = New-Object Text.StringBuilder 4096
$count = [AndroidWorkspaceDevice]::QueryDosDevice('R:', $buffer, $buffer.Capacity)
$expected = '\??\' + $physicalWorkspace
$created = $false
if ($count -eq 0) {
    & subst.exe R: $physicalWorkspace
    if ($LASTEXITCODE -ne 0) {throw 'Temporary workspace mapping failed'}
    $created = $true
    $buffer = New-Object Text.StringBuilder 4096
    $count = [AndroidWorkspaceDevice]::QueryDosDevice('R:', $buffer, $buffer.Capacity)
}
if ($count -eq 0 -or $buffer.ToString() -ne $expected) {throw 'R drive is not this workspace; no alias writes allowed'}
$project = 'R:/shiyu'
$tools = Join-Path $project '.toolchains'
$evidence = Join-Path $project 'planning/media-v11/results'
New-Item -ItemType Directory -Path $evidence -Force|Out-Null
[pscustomobject]@{drive='R:';target=$physicalWorkspace;createdByThisBootstrap=$created;verified=$true;temporary=$true;cleanupRequired=$true}|ConvertTo-Json|Set-Content (Join-Path $evidence 'workspace-mapping.json') -Encoding utf8
$metadata = Get-Content (Join-Path $project 'planning/media-v10/android-toolchain-metadata-v0.10.json') -Raw|ConvertFrom-Json
function Get-VerifiedArchive($url, $bytes, $sha, $filename) {
    if ($bytes -le 0 -or $bytes -gt 300MB -or $sha -notmatch '^[a-fA-F0-9]{64}$') {throw 'Unexpected bootstrap package identity'}
    if ($url -notlike 'https://github.com/adoptium/temurin17-binaries/releases/download/*' -and $url -ne 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip') {throw 'Unapproved bootstrap URL'}
    $target = Join-Path $tools ('downloads/' + $filename)
    $part = $target + '.partial'
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "Downloading verified candidate $filename ($bytes bytes)."
        & curl.exe --fail --location --proto '=https' --proto-redir '=https' --silent --show-error --connect-timeout 15 --max-time 1800 --max-filesize $bytes --continue-at - --output $part $url
        if ($LASTEXITCODE -ne 0) {throw 'Bootstrap download incomplete; prefix retained, not executed'}
        if ((Get-Item -LiteralPath $part).Length -ne $bytes -or (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha.ToLowerInvariant()) {throw 'Bootstrap archive identity mismatch'}
        Move-Item -LiteralPath $part -Destination $target
    } else {
        if ((Get-Item -LiteralPath $target).Length -ne $bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha.ToLowerInvariant()) {throw 'Cached bootstrap archive identity mismatch'}
    }
    return $target
}
function Expand-VerifiedArchive($archive, $destination, $requiredPrefix) {
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if (-not $name.StartsWith($requiredPrefix + '/') -or $name -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($name)) {throw 'Archive entry outside expected package root'}
        }
    } finally {$zip.Dispose()}
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    & tar.exe -xf $archive -C $destination
    if ($LASTEXITCODE -ne 0) {throw 'Verified archive extraction failed'}
}
$jdkFile = Split-Path ([uri]$metadata.jdk.url).AbsolutePath -Leaf
$jdkArchive = Get-VerifiedArchive $metadata.jdk.url $metadata.jdk.size_bytes $metadata.jdk.sha256 $jdkFile
$jdk = Join-Path $tools 'jdk-17.0.21+9'
if (-not (Test-Path (Join-Path $jdk 'bin/java.exe'))) {Expand-VerifiedArchive $jdkArchive $tools 'jdk-17.0.21+9'}
$cliArchive = Get-VerifiedArchive $metadata.android_commandline_tools.url $metadata.android_commandline_tools.size_bytes $metadata.android_commandline_tools.sha256 $metadata.android_commandline_tools.file
$sdk = Join-Path $tools 'android-sdk'
$cli = Join-Path $sdk 'cmdline-tools/22.0'
if (-not (Test-Path (Join-Path $cli 'bin/sdkmanager.bat'))) {
    if (Test-Path -LiteralPath $cli) {throw 'Partial command-line tool destination exists; inspect before retry'}
    $staging = Join-Path $tools 'unpack-android-cli'
    Expand-VerifiedArchive $cliArchive $staging 'cmdline-tools'
    $source = [IO.Path]::GetFullPath((Join-Path $staging 'cmdline-tools'))
    $target = [IO.Path]::GetFullPath($cli)
    $allowed = [IO.Path]::GetFullPath($tools).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $source.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or -not $target.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) {throw 'CLI directory move outside dedicated tools'}
    New-Item -ItemType Directory -Path (Split-Path $cli -Parent) -Force|Out-Null
    Move-Item -LiteralPath $source -Destination $target
}
$env:JAVA_HOME = $jdk
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_USER_HOME = Join-Path $tools 'android-user'
$env:GRADLE_USER_HOME = Join-Path $tools 'gradle-cache'
$env:PUB_CACHE = Join-Path $tools 'pub-cache'
$env:PATH = (Join-Path $jdk 'bin') + ';' + $env:PATH
$javaOutput = & (Join-Path $jdk 'bin/java.exe') -version 2>&1|Out-String
$javaCode = $LASTEXITCODE
$javaOutput|Set-Content (Join-Path $evidence 'java-version.log') -Encoding utf8
Write-Output $javaOutput
if ($javaCode -ne 0) {throw 'Private JDK failed self-check'}
$cliOutput = & (Join-Path $cli 'bin/sdkmanager.bat') --sdk_root=$sdk --version 2>&1|Out-String
$cliCode = $LASTEXITCODE
$cliOutput|Set-Content (Join-Path $evidence 'sdkmanager-version.log') -Encoding utf8
Write-Output $cliOutput
[pscustomobject]@{stage='bootstrap_only';jdkVersionExit=$javaCode;sdkmanagerVersionExit=$cliCode;jdkPath=$jdk;sdkPath=$sdk;globalJavaChanged=$false;deviceConnectedByTask=$false}|ConvertTo-Json|Set-Content (Join-Path $evidence 'bootstrap-result.json') -Encoding utf8
if ($cliCode -ne 0) {throw 'SDK manager runtime compatibility failed; inspect before installing components'}
Write-Output 'Bootstrap verified. SDK component install and approved license prompt remain a separate step.'
