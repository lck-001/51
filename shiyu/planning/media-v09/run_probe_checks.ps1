$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolRoot = Join-Path $projectRoot '.toolchains'
$sdk = Join-Path $toolRoot 'flutter'
$probe = Join-Path $toolRoot 'media-probe'
$evidence = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
if (-not (Test-Path (Join-Path $toolRoot 'flutter-extracted.json'))) {throw 'Verified extraction required before checks'}
$env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $toolRoot 'gradle-cache'
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
$env:CI = 'true'
$flutter = Join-Path $sdk 'bin/flutter.bat'
$dart = Join-Path $sdk 'bin/cache/dart-sdk/bin/dart.exe'
$records = @()
function Run-Step($name, $exe, $arguments, $location, $required) {
    Push-Location $location
    try {
        $started = (Get-Date).ToString('o')
        $output = & $exe @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $output | Set-Content (Join-Path $evidence ($name + '.log')) -Encoding utf8
        $record = [pscustomobject]@{step=$name;exitCode=$code;startedAt=$started;finishedAt=(Get-Date).ToString('o');log=($name+'.log')}
        $script:records += $record
        $script:records | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'execution.json') -Encoding utf8
        $record | ConvertTo-Json -Compress
        if ($code -ne 0) {
            ($output -split "`n" | Select-Object -Last 14) -join "`n" | Write-Output
            if ($required) {throw "Required step failed: $name; inspect log before retry"}
        }
    } finally { Pop-Location }
}
Run-Step 'flutter-version' $flutter @('--suppress-analytics','--no-version-check','--version','--machine') $projectRoot $true
Run-Step 'dart-version' $dart @('--suppress-analytics','--version') $projectRoot $true
if (Test-Path -LiteralPath $probe) {throw 'Probe directory already exists; inspect previous results before regeneration'}
Run-Step 'create-probe' $flutter @('--suppress-analytics','--no-version-check','create','--no-pub','--empty','--platforms=windows,android','--org=com.shiyu.probe','--project-name=shiyu_media_probe',$probe) $projectRoot $true
$source = Join-Path $projectRoot 'validation/media-01'
Run-Step 'format-source' $dart @('--suppress-analytics','format',(Join-Path $source 'lib/main.dart')) $projectRoot $true
Copy-Item -LiteralPath (Join-Path $source 'pubspec.yaml') -Destination (Join-Path $probe 'pubspec.yaml')
Copy-Item -LiteralPath (Join-Path $source 'lib/main.dart') -Destination (Join-Path $probe 'lib/main.dart')
# The generated runner is a disposable experiment, with no platform execution here.
Run-Step 'pub-get' $flutter @('--suppress-analytics','--no-version-check','pub','get') $probe $true
Copy-Item -LiteralPath (Join-Path $probe 'pubspec.lock') -Destination (Join-Path $evidence 'pubspec.lock')
Run-Step 'analyze' $flutter @('--suppress-analytics','--no-version-check','analyze','--no-pub') $probe $false
Run-Step 'doctor' $flutter @('--suppress-analytics','--no-version-check','doctor','-v') $probe $false
Write-Output 'Checks finished; no app started, camera/microphone permissions requested, or phone connected.'
