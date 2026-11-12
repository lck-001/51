param([ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$LogPrefix = 'android-debug-build-permission-fix')
$ErrorActionPreference = 'Stop'
$tools = 'R:/shiyu/.toolchains'
$env:JAVA_HOME = Join-Path $tools 'jdk-17.0.21+9'
$env:ANDROID_HOME = Join-Path $tools 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $tools 'android-user'
$env:GRADLE_USER_HOME = Join-Path $tools 'gradle-cache'
$env:PUB_CACHE = Join-Path $tools 'pub-cache'
$env:FLUTTER_ROOT = Join-Path $tools 'flutter'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:CI = 'true'
$tmp = Join-Path $tools 'tmp'
$env:TEMP = $tmp
$env:TMP = $tmp
$env:JAVA_TOOL_OPTIONS = '-Djava.io.tmpdir=' + $tmp.Replace('\','/')
$env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
$evidence = 'R:/shiyu/planning/media-v11/results'
Push-Location (Join-Path $tools 'media-probe')
try {
    $started = (Get-Date).ToString('o')
    $output = & (Join-Path $tools 'flutter/bin/flutter.bat') --suppress-analytics --no-version-check build apk --debug --no-pub 2>&1 | Tee-Object -FilePath (Join-Path $evidence ($LogPrefix + '.log')) | Out-String
    $code = $LASTEXITCODE
    [pscustomobject]@{step=$LogPrefix;exitCode=$code;startedAt=$started;finishedAt=(Get-Date).ToString('o');version='0.0.2+2';phoneAccessed=$false} | ConvertTo-Json | Set-Content (Join-Path $evidence ($LogPrefix + '.json')) -Encoding utf8
    [pscustomobject]@{step=$LogPrefix;exitCode=$code} | ConvertTo-Json -Compress
    ($output -split "`n" | Select-Object -Last 40) -join "`n" | Write-Output
    if ($code -ne 0) {throw 'Android build failed; inspect actual log'}
} finally {Pop-Location}
