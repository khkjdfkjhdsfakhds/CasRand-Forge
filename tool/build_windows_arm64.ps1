# Run with Flutter 3.44.6, Visual Studio 2022 C++ ARM64 tools, and Rust on PATH.
# Keep the plugin compatibility patch in a build-local Pub cache.
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$previousPubCache = $env:PUB_CACHE
Push-Location $root
try {
    if ((& dart --version) -notmatch 'windows_arm64') {
        throw 'Run this script with the native ARM64 Flutter/Dart SDK on Windows ARM64'
    }
    $env:PUB_CACHE = Join-Path $root 'build\windows-arm64-pub-cache'
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }

    # Cargokit shipped with super_native_extensions 0.8.x omits this target.
    $configPath = Join-Path $root '.dart_tool\package_config.json'
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $package = $config.packages | Where-Object name -eq 'super_native_extensions'
    if (-not $package) { throw 'super_native_extensions is missing' }
    $packageRoot = ([Uri]::new([Uri]$configPath, $package.rootUri)).LocalPath
    if (-not $packageRoot.StartsWith($env:PUB_CACHE, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to patch a shared Pub cache'
    }
    $targetFile = Join-Path $packageRoot 'cargokit\build_tool\lib\src\target.dart'
    $source = [IO.File]::ReadAllText($targetFile)
    if (-not $source.Contains("flutter: 'windows-arm64'")) {
        $anchor = "      rust: 'x86_64-pc-windows-msvc',"
        if (-not $source.Contains($anchor)) { throw 'Cargokit target list has changed' }
        $replacement = "      rust: 'aarch64-pc-windows-msvc',`n      flutter: 'windows-arm64',`n    ),`n    Target(`n$anchor"
        [IO.File]::WriteAllText($targetFile, $source.Replace($anchor, $replacement), [Text.UTF8Encoding]::new($false))
    }

    # Flutter 3.44 selects the Windows architecture from its native host SDK.
    # Windows PowerShell treats even CMake's informational stderr as an error;
    # use the build exit code to distinguish warnings from build failures.
    $ErrorActionPreference = 'Continue'
    & flutter build windows --release
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($buildExit -ne 0) { throw 'Windows ARM64 build failed' }
    $release = Join-Path $root 'build\windows\arm64\runner\Release'
    # Every executable and plugin must be native ARM64; mixed DLLs cannot load.
    Get-ChildItem $release -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or
            [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xaa64) {
            throw "Not an ARM64 PE: $($_.Name)"
        }
    }
    $aot = [IO.File]::ReadAllBytes((Join-Path $release 'data\app.so'))
    if ([BitConverter]::ToUInt32($aot, 0) -ne 0x464c457f -or
        [BitConverter]::ToUInt16($aot, 18) -ne 183) { throw 'Not an ARM64 AOT snapshot' }
    $version = (Get-Content 'pubspec.yaml' | Select-String '^version: (.+)$').Matches[0].Groups[1].Value
    if ((Get-Item (Join-Path $release 'NAICasRandForge.exe')).VersionInfo.ProductVersion -ne $version) {
        throw 'Windows product version does not match pubspec.yaml'
    }
    $parts = $version.Split('+')[0].Split('.')
    $tag = "v$($parts[0]).$($parts[1])$($parts[2])"
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build\artifacts' }
    New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
    $archive = Join-Path (Resolve-Path $OutputDirectory).Path "NAI-CasRand-Forge-$tag-Z-Windows-arm64.zip"
    & tar.exe -a -c -f $archive -C $release .
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
    Get-FileHash $archive -Algorithm SHA256
} finally {
    $env:PUB_CACHE = $previousPubCache
    Pop-Location
}
