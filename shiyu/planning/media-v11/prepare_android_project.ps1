# Source-only preparation. Does not install, build, accept licenses, or contact devices.
[CmdletBinding()]
param(
    [string]$AndroidProject = 'R:/shiyu/.toolchains/media-probe/android',
    [string]$SdkRoot = 'R:/shiyu/.toolchains/android-sdk',
    [string]$FlutterRoot = 'R:/shiyu/.toolchains/flutter'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [System.Text.UTF8Encoding]::new($false)
$androidNs = 'http://schemas.android.com/apk/res/android'
$toolsNs = 'http://schemas.android.com/tools'

# Restrict writes to the existing Android runner in this project, including the
# already-used R: alias. This script never creates or edits user profile files.
$allowedProjects = @(
    'R:/shiyu/.toolchains/media-probe/android',
    'C:/src/51/shiyu/.toolchains/media-probe/android'
) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
$project = [IO.Path]::GetFullPath($AndroidProject).TrimEnd('\', '/')
if ($project -notin $allowedProjects -or -not (Test-Path -LiteralPath $project -PathType Container)) {
    throw 'Unexpected Android project target; no files changed.'
}
foreach ($root in @($SdkRoot, $FlutterRoot)) {
    if ($root -match '[\r\n=]' -or $root.Replace('\', '/').TrimEnd('/') -notin @(
        'R:/shiyu/.toolchains/android-sdk',
        'R:/shiyu/.toolchains/flutter'
    )) { throw 'Unexpected toolchain path; no files changed.' }
}
if ($SdkRoot.Replace('\', '/').TrimEnd('/') -ne 'R:/shiyu/.toolchains/android-sdk' -or
    $FlutterRoot.Replace('\', '/').TrimEnd('/') -ne 'R:/shiyu/.toolchains/flutter') {
    throw 'SDK and Flutter paths must retain their approved roles.'
}

function Read-RunnerFile([string]$RelativePath) {
    $path = Join-Path $project $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runner file: $RelativePath" }
    return [IO.File]::ReadAllText($path)
}
function Set-Property([string]$Text, [string]$Key, [string]$Value) {
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
    if ([regex]::Matches($Text, $pattern).Count -gt 1) { throw "Duplicate property: $Key" }
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m) "$Key=$Value"
        })
    }
    return $Text.TrimEnd() + "`n$Key=$Value`n"
}
function Write-RunnerFile([string]$RelativePath, [string]$Text) {
    $path = [IO.Path]::GetFullPath((Join-Path $project $RelativePath))
    if (-not $path.StartsWith($project + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Write escaped Android runner.'
    }
    $previous = [IO.File]::ReadAllText($path)
    if ($previous -ceq $Text) { return }
    $backup = $path + '.v11.before'
    if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllText($backup, $previous, $utf8) }
    [IO.File]::WriteAllText($path + '.v11.tmp', $Text, $utf8)
    Move-Item -LiteralPath ($path + '.v11.tmp') -Destination $path -Force
    [pscustomobject]@{ file = $RelativePath; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}

# Validate every input first. No main.dart/pubspec or captured media is read.
$manifestText = Read-RunnerFile 'app/src/main/AndroidManifest.xml'
$gradleText = Read-RunnerFile 'gradle.properties'
$localText = Read-RunnerFile 'local.properties'
$settingsText = Read-RunnerFile 'settings.gradle.kts'
$wrapperText = Read-RunnerFile 'gradle/wrapper/gradle-wrapper.properties'
if ($settingsText -notmatch 'version "9\.3\.1"' -or $settingsText -notmatch 'version "2\.4\.20"' -or
    $wrapperText -notmatch 'gradle-9\.5\.0-all\.zip') { throw 'Runner versions changed; re-review before preparing.' }
foreach ($flag in @('android.newDsl', 'android.builtInKotlin')) {
    if ($gradleText -notmatch ('(?m)^' + [regex]::Escape($flag) + '=false\s*$')) {
        throw "Expected existing compatibility flag missing: $flag"
    }
}
$manifest = [xml]::new()
$manifest.PreserveWhitespace = $true
$manifest.LoadXml($manifestText)
$allowedPermissions = @('android.permission.CAMERA', 'android.permission.RECORD_AUDIO')
$removedPermissions = @('android.permission.READ_EXTERNAL_STORAGE', 'android.permission.WRITE_EXTERNAL_STORAGE')
foreach ($permission in $manifest.DocumentElement.SelectNodes('uses-permission')) {
    $permissionName = $permission.GetAttribute('name', $androidNs)
    $mergeAction = $permission.GetAttribute('node', $toolsNs)
    if ($permissionName -in $removedPermissions -and $mergeAction -eq 'remove') { continue }
    if ($permissionName -notin $allowedPermissions -or $mergeAction) {
        throw 'Main manifest has an unexpected permission; re-review instead of deleting it.'
    }
}
foreach ($relative in @('app/src/debug/AndroidManifest.xml', 'app/src/profile/AndroidManifest.xml')) {
    $development = [xml](Read-RunnerFile $relative)
    foreach ($permission in $development.DocumentElement.SelectNodes('uses-permission')) {
        if ($permission.GetAttribute('name', $androidNs) -ne 'android.permission.INTERNET') {
            throw "Unexpected development permission in $relative"
        }
    }
}
if ($manifest.DocumentElement.GetNamespaceOfPrefix('tools') -ne $toolsNs) {
    $toolsDeclaration = $manifest.CreateAttribute('xmlns', 'tools', 'http://www.w3.org/2000/xmlns/')
    $toolsDeclaration.Value = $toolsNs
    [void]$manifest.DocumentElement.Attributes.Append($toolsDeclaration)
}
foreach ($name in $removedPermissions) {
    $existing = @($manifest.DocumentElement.SelectNodes('uses-permission') | Where-Object {
        $_.GetAttribute('name', $androidNs) -eq $name
    })
    if ($existing.Count -gt 1) { throw "Duplicate storage removal node: $name" }
    if ($existing.Count -eq 0) {
        $permission = $manifest.CreateElement('uses-permission')
        $nameAttribute = $manifest.CreateAttribute('android', 'name', $androidNs)
        $nameAttribute.Value = $name
        [void]$permission.Attributes.Append($nameAttribute)
        $removeAttribute = $manifest.CreateAttribute('tools', 'node', $toolsNs)
        $removeAttribute.Value = 'remove'
        [void]$permission.Attributes.Append($removeAttribute)
        [void]$manifest.DocumentElement.PrependChild($permission)
        [void]$manifest.DocumentElement.InsertAfter($manifest.CreateWhitespace("`n    "), $permission)
    }
}
foreach ($name in $allowedPermissions) {
    $existing = @($manifest.DocumentElement.SelectNodes('uses-permission') | Where-Object {
        $_.GetAttribute('name', $androidNs) -eq $name
    })
    if ($existing.Count -eq 0) {
        $permission = $manifest.CreateElement('uses-permission')
        $attribute = $manifest.CreateAttribute('android', 'name', $androidNs)
        $attribute.Value = $name
        [void]$permission.Attributes.Append($attribute)
        [void]$manifest.DocumentElement.PrependChild($permission)
        [void]$manifest.DocumentElement.InsertAfter($manifest.CreateWhitespace("`n    "), $permission)
    }
}
$localText = Set-Property $localText 'sdk.dir' $SdkRoot.Replace('\', '/')
$localText = Set-Property $localText 'flutter.sdk' $FlutterRoot.Replace('\', '/')
$localText = Set-Property $localText 'cmake.dir' ($SdkRoot.Replace('\', '/').TrimEnd('/') + '/cmake/3.22.1')
$gradleText = Set-Property $gradleText 'org.gradle.jvmargs' '-Xmx2G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m -XX:+HeapDumpOnOutOfMemoryError'
$gradleText = Set-Property $gradleText 'org.gradle.workers.max' '2'
$gradleText = Set-Property $gradleText 'org.gradle.parallel' 'false'
$gradleText = Set-Property $gradleText 'kotlin.daemon.jvmargs' '-Xmx768m'

Write-RunnerFile 'app/src/main/AndroidManifest.xml' $manifest.OuterXml
Write-RunnerFile 'local.properties' $localText
Write-RunnerFile 'gradle.properties' $gradleText
Write-Output 'Prepared Android runner files only. No install/build/device command was run.'
