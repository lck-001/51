$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tools = Join-Path $project '.toolchains'
$probe = Join-Path $tools 'media-probe'
$build = Join-Path $tools 'c'
$cmake = Join-Path $tools 'cmake-3.31.12-windows-x86_64/bin/cmake.exe'
$evidence = Join-Path $PSScriptRoot 'results'
if (-not [IO.Path]::GetFullPath($build).StartsWith($tools + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {throw 'Build directory outside dedicated tool/experiment root'}
if (-not (Test-Path (Join-Path $probe 'windows/flutter/ephemeral/generated_config.cmake'))) {throw 'Flutter-generated configuration required'}
$env:PUB_CACHE = Join-Path $tools 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $tools 'gradle-cache'
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
$env:CI = 'true'
Push-Location $probe
try {
    $start = (Get-Date).ToString('o')
    $output = & $cmake -S (Join-Path $probe 'windows') -B $build -G 'Visual Studio 16 2019' -A x64 '-DFLUTTER_TARGET_PLATFORM=windows-x64' 2>&1 | Out-String
    $code = $LASTEXITCODE
    $output | Set-Content (Join-Path $evidence 'portable-cmake-configure.log') -Encoding utf8
    [pscustomobject]@{step='portable-cmake-configure';exitCode=$code;startedAt=$start;finishedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $evidence 'portable-cmake-configure.json') -Encoding utf8
    [pscustomobject]@{step='portable-cmake-configure';exitCode=$code}|ConvertTo-Json -Compress
    if ($code -ne 0) {$output; throw 'Portable CMake configuration failed'}
    $cache = Get-Content (Join-Path $build 'CMakeCache.txt')
    $install = @($cache | Where-Object {$_ -match '^CMAKE_INSTALL_PREFIX:PATH='})
    $generator = @($cache | Where-Object {$_ -match '^CMAKE_GENERATOR:INTERNAL='})
    $instance = @($cache | Where-Object {$_ -match '^CMAKE_GENERATOR_INSTANCE:INTERNAL='})
    if ($generator.Count -ne 1 -or $generator[0] -ne 'CMAKE_GENERATOR:INTERNAL=Visual Studio 16 2019') {throw 'Unexpected generator'}
    # Official template sets the install prefix to its target's output directory.
    if ($install.Count -ne 1 -or $install[0] -ne 'CMAKE_INSTALL_PREFIX:PATH=$<TARGET_FILE_DIR:shiyu_media_probe>') {throw 'Unexpected install prefix; do not run INSTALL'}
    $installScript = Get-Content (Join-Path $build 'cmake_install.cmake') -Raw
    $expectedBundle = (Join-Path $build 'runner').Replace('\','/')
    if ($installScript -notmatch [regex]::Escape($expectedBundle)) {throw 'Install destination does not resolve to this build bundle'}
    [pscustomobject]@{generator=$generator[0];instance=$instance;installPrefix=$install[0];expectedBundle=$expectedBundle;scope='INSTALL may recreate data/flutter_assets only within this task-owned bundle'}|ConvertTo-Json -Depth 4|Set-Content (Join-Path $evidence 'portable-build-path-check.json') -Encoding utf8
    $start = (Get-Date).ToString('o')
    $output = & $cmake --build $build --config Debug --target INSTALL 2>&1 | Out-String
    $code = $LASTEXITCODE
    $output | Set-Content (Join-Path $evidence 'portable-cmake-build.log') -Encoding utf8
    [pscustomobject]@{step='portable-cmake-build';exitCode=$code;startedAt=$start;finishedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $evidence 'portable-cmake-build.json') -Encoding utf8
    [pscustomobject]@{step='portable-cmake-build';exitCode=$code}|ConvertTo-Json -Compress
    ($output -split "`n" | Select-Object -Last 35) -join "`n" | Write-Output
    if ($code -ne 0) {throw 'Portable CMake native build failed'}
    $exe = Join-Path $build 'runner/Debug/shiyu_media_probe.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {throw 'Build reported success without expected executable'}
    [pscustomobject]@{executable=$exe;sizeBytes=(Get-Item $exe).Length;sha256=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant();appStarted=$false}|ConvertTo-Json|Set-Content (Join-Path $evidence 'windows-executable.json') -Encoding utf8
} finally {Pop-Location}
