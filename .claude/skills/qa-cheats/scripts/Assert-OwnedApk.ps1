<#
.SYNOPSIS
    Ownership gate: proves an APK belongs to Sonat before any QA patching runs. Fails closed.

.DESCRIPTION
    Reads the package name (aapt) and signing certificate (apksigner) from the APK and checks
    them against qa-config.json. Writes <OutDir>/ownership.json with an explicit verdict and
    prints it. Verdict values:
      OWNED            package matches a prefix (and cert matches, if cert list is set)
      NOT_OWNED        package does not match any configured prefix  -> caller must stop
      CERT_MISMATCH    package matches but signing cert is not in ownedCertSha256 -> stop
      CANNOT_ASSESS    config missing/empty, or tools unavailable  -> stop (never proceeds)

    CANNOT_ASSESS and NOT_OWNED are NOT the same as OWNED. The caller proceeds only on OWNED.
    An empty ownedPackagePrefixes is CANNOT_ASSESS, not "allow all": the gate fails closed.

.NOTES
    Package-prefix matching alone is spoofable. Set ownedCertSha256 for a gate that cannot be
    satisfied by simply renaming a package. This is stated in the verdict's `warnings`.
#>
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$BuildToolsDir
)

$ErrorActionPreference = 'Stop'
$ApkPath = (Resolve-Path -LiteralPath $ApkPath).Path
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFile = Join-Path $OutDir 'ownership.json'

function Emit([string]$verdict, $package, $certs, [string[]]$warnings, [string]$detail) {
    $result = [ordered]@{
        verdict  = $verdict
        apk      = $ApkPath
        package  = $package
        certSha256 = $certs
        detail   = $detail
        warnings = @($warnings)
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outFile -Encoding UTF8
    $result | ConvertTo-Json -Depth 5
    # Only OWNED and GATE_SKIPPED continue. GATE_SKIPPED = no qa-config.json (gitignored, per-dev):
    # the user chose to run without the gate. It is announced loudly, never reported as OWNED.
    if ($verdict -ne 'OWNED' -and $verdict -ne 'GATE_SKIPPED') { exit 3 }
}

# --- config ---
# qa-config.json is per-dev and gitignored. If it does not exist the ownership gate is
# SKIPPED (verdict GATE_SKIPPED, exit 0) and the build proceeds. If it exists, the gate runs
# in full and still fails closed (empty prefixes => CANNOT_ASSESS).
$gateSkipped = -not (Test-Path -LiteralPath $ConfigPath)
$prefixes = @(); $ownedCerts = @()
if (-not $gateSkipped) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $prefixes = @($config.ownedPackagePrefixes | Where-Object { $_ })
    $ownedCerts = @($config.ownedCertSha256 | Where-Object { $_ } | ForEach-Object { ($_ -replace '[^0-9a-fA-F]', '').ToLowerInvariant() })
    if ($prefixes.Count -eq 0) {
        Emit 'CANNOT_ASSESS' $null @() @("ownedPackagePrefixes is empty. The gate fails closed: set at least one prefix (e.g. com.sonat.) to declare which APKs are yours.") 'no prefixes configured'
    }
}

# --- locate tools ---
if (-not $BuildToolsDir) {
    $sdk = $env:ANDROID_HOME; if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
    if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $bt = Join-Path $sdk 'build-tools'
    if (Test-Path -LiteralPath $bt) {
        $BuildToolsDir = (Get-ChildItem -LiteralPath $bt -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
}
$aapt = Join-Path $BuildToolsDir 'aapt.exe'
$apksigner = Join-Path $BuildToolsDir 'apksigner.bat'
if (-not (Test-Path -LiteralPath $aapt)) {
    Emit 'CANNOT_ASSESS' $null @() @("aapt not found under build-tools ($BuildToolsDir). Install Android SDK build-tools or pass -BuildToolsDir.") 'aapt missing'
}

# --- package name ---
$badging = & $aapt dump badging $ApkPath 2>$null
$pkgLine = $badging | Where-Object { $_ -match "^package: name='([^']+)'" } | Select-Object -First 1
$package = if ($pkgLine -match "name='([^']+)'") { $Matches[1] } else { $null }
if (-not $package) {
    Emit 'CANNOT_ASSESS' $null @() @("Could not read package name from the APK via aapt.") 'package unreadable'
}

if ($gateSkipped) {
    Write-Warning "OWNERSHIP GATE SKIPPED: no qa-config.json at $ConfigPath. Package '$package' was NOT verified as Sonat's. Only use this on a Sonat build."
    Emit 'GATE_SKIPPED' $package @() @("No qa-config.json at $ConfigPath: ownership gate was skipped, package '$package' is unverified. Copy qa-config.example.json to qa-config.json to enable the gate.") 'config missing, gate skipped by design'
}

$matchedPrefix = $prefixes | Where-Object { $package.StartsWith($_) } | Select-Object -First 1
if (-not $matchedPrefix) {
    Emit 'NOT_OWNED' $package @() @("Package '$package' matches none of: $($prefixes -join ', '). This APK is not recognised as a Sonat build; QA patching is refused.") 'prefix mismatch'
}

# --- signing cert ---
$certs = @()
if (Test-Path -LiteralPath $apksigner) {
    $printed = & $apksigner verify --print-certs $ApkPath 2>$null
    $certs = @($printed | Where-Object { $_ -match 'SHA-256 digest:\s*([0-9a-fA-F]+)' } | ForEach-Object {
        [regex]::Match($_, 'SHA-256 digest:\s*([0-9a-fA-F]+)').Groups[1].Value.ToLowerInvariant()
    })
}

$warnings = @()
if ($ownedCerts.Count -gt 0) {
    $certOk = $certs | Where-Object { $ownedCerts -contains $_ } | Select-Object -First 1
    if (-not $certOk) {
        Emit 'CERT_MISMATCH' $package $certs @("Package prefix matched but the signing certificate is not in ownedCertSha256. If this really is your build, add its SHA-256 to the config; otherwise it is not yours.") 'cert mismatch'
    }
} else {
    $warnings += "ownedCertSha256 is not set: the gate passed on package-prefix alone, which is spoofable. Add your cert SHA-256 for a stronger gate. Observed cert(s): $($certs -join ', ')"
}

Emit 'OWNED' $package $certs $warnings "matched prefix '$matchedPrefix'"
