<#
.SYNOPSIS
    Produces a QA cheat build of a Sonat Unity IL2CPP APK: ownership gate -> symbol dump ->
    Frida-gadget embed -> re-sign with the QA key. Refuses any APK that is not Sonat's.

.DESCRIPTION
    Every stage writes a status line and stops the pipeline on failure; a stage that could not
    run is reported by name (never skipped silently). Output: <OutDir>/<name>_QA.apk plus
    cheat-symbols.json and patch.js for review.

    This instruments Sonat's OWN app for QA. It is gated to owned packages, renames the app so a
    QA build cannot be mistaken for a store build, and signs with a QA key (never the release key).
#>
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [string]$ConfigPath,
    [string]$OutDir,
    [string]$SkillRoot,
    [string]$DumperExe,
    [switch]$AssumeYes  # skip the interactive confirmation (caller already confirmed)
)

$ErrorActionPreference = 'Stop'
if (-not $SkillRoot) { $SkillRoot = Split-Path (Split-Path $PSCommandPath) }
$scripts = Join-Path $SkillRoot 'scripts'
if (-not $ConfigPath) { $ConfigPath = Join-Path $scripts 'qa-config.json' }
$ApkPath = (Resolve-Path -LiteralPath $ApkPath).Path
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $ApkPath) 'qa-build' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Stage([string]$s) { Write-Host "`n=== $s ===" }
function Fail([string]$s) { Write-Error $s; exit 1 }

# --- Stage 1: ownership gate (hard stop) ---------------------------------------------------
Stage 'Ownership gate'
& (Join-Path $scripts 'Assert-OwnedApk.ps1') -ApkPath $ApkPath -ConfigPath $ConfigPath -OutDir $OutDir
if ($LASTEXITCODE -ne 0) { Fail "Ownership gate did not return OWNED (exit $LASTEXITCODE). This APK is not confirmed as Sonat's; QA patching is refused. See $OutDir\ownership.json." }
$gateVerdict = (Get-Content (Join-Path $OutDir 'ownership.json') -Raw | ConvertFrom-Json).verdict
if ($gateVerdict -eq 'GATE_SKIPPED') {
    Write-Warning "GATE SKIPPED (no qa-config.json): this APK's ownership was NOT verified. Continuing by design."
}

# --- Stage 2: tools present? (announce what is missing, do not half-run) --------------------
Stage 'Tool check'
$missing = @()
foreach ($t in @(
    @{ n = 'apktool';   c = { Get-Command apktool -ErrorAction SilentlyContinue } },
    @{ n = 'objection'; c = { Get-Command objection -ErrorAction SilentlyContinue } }
)) { if (-not (& $t.c)) { $missing += $t.n } }
$sdk = $env:ANDROID_HOME; if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$bt = (Get-ChildItem (Join-Path $sdk 'build-tools') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $bt) { $missing += 'android-build-tools' }
if (-not $DumperExe) {
    $DumperExe = (Get-ChildItem (Join-Path $SkillRoot '..\..\..\_reference\tools') -Recurse -Filter 'Il2CppDumper.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $DumperExe -or -not (Test-Path -LiteralPath $DumperExe)) { $missing += 'Il2CppDumper.exe' }
if ($missing.Count) {
    Fail ("Missing tools: {0}. Install them before running (see references/setup.md), e.g. `py -m pip install objection frida-tools`, Scoop/apktool, Android build-tools. Nothing was patched." -f ($missing -join ', '))
}

# --- Stage 3: engine check (RVA-based cheats need Unity IL2CPP) -----------------------------
Stage 'Engine check'
$workApk = Join-Path $OutDir '_apk'
if (Test-Path $workApk) { Remove-Item $workApk -Recurse -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($ApkPath, $workApk)
$lib = Get-ChildItem $workApk -Recurse -Filter 'libil2cpp.so' | Select-Object -First 1
$meta = Get-ChildItem $workApk -Recurse -Filter 'global-metadata.dat' | Select-Object -First 1
if (-not $lib -or -not $meta) {
    Fail "No libil2cpp.so / global-metadata.dat in this APK. This skill only automates Unity IL2CPP builds. Engine: NOT IL2CPP — patching refused."
}
$abi = $lib.Directory.Name
Write-Host "IL2CPP, abi = $abi"

# --- Stage 4: symbol dump ------------------------------------------------------------------
Stage 'Symbol dump (Il2CppDumper)'
$dumpDir = Join-Path $OutDir 'dump'
New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
& $DumperExe $lib.FullName $meta.FullName $dumpDir
$dumpCs = Join-Path $dumpDir 'dump.cs'
if (-not (Test-Path -LiteralPath $dumpCs)) { Fail "Il2CppDumper produced no dump.cs (metadata encrypted/obfuscated?). Cannot locate cheat functions — refused. See teardown troubleshooting." }

# --- Stage 5: find cheat symbols + build patch.js ------------------------------------------
Stage 'Cheat symbol discovery'
node (Join-Path $scripts 'find-cheat-symbols.mjs') $dumpCs (Join-Path $scripts 'patch-template.js') $OutDir
$symbolsExit = $LASTEXITCODE
$package = ((Get-Content (Join-Path $OutDir 'ownership.json') -Raw | ConvertFrom-Json).package)
(Get-Content (Join-Path $OutDir 'patch.js') -Raw).Replace('__PKG__', $package) | Set-Content (Join-Path $OutDir 'patch.js') -Encoding UTF8
if ($symbolsExit -eq 2) {
    Write-Warning "No cheat functions matched. patch.js was written but every slot is NOT FOUND. Map them by hand in dump.cs before the build is useful."
}

# --- Stage 6: confirmation (side-effectful from here) --------------------------------------
if (-not $AssumeYes) {
    Fail "Review $OutDir\cheat-symbols.json and patch.js, then re-run with -AssumeYes to embed Frida and sign. Stopping before producing an installable APK."
}

# --- Stage 7: embed Frida gadget + script via objection ------------------------------------
Stage 'Embed Frida gadget'
Push-Location $OutDir
try {
    & objection patchapk --source $ApkPath --gadget-version latest `
        --script (Join-Path $OutDir 'patch.js') --architecture $abi --skip-resources
    if ($LASTEXITCODE -ne 0) { Fail "objection patchapk failed (exit $LASTEXITCODE)." }
} finally { Pop-Location }
$patched = Get-ChildItem $OutDir -Filter '*.objection.apk' | Select-Object -First 1
if (-not $patched) { Fail "objection did not produce a patched APK." }

# --- Stage 8: zipalign + sign with the QA key ----------------------------------------------
Stage 'Align + QA sign'
# No qa-config.json (gate skipped): take the QA keystore from env vars instead.
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} else {
    $config = [pscustomobject]@{ qaKeystore = [pscustomobject]@{ path = $env:QA_KEYSTORE_PATH; alias = $env:QA_KEYSTORE_ALIAS } }
}
$ks = $config.qaKeystore.path
if (-not $ks -or -not (Test-Path -LiteralPath $ks)) { Fail "QA keystore not set or not found. Set qaKeystore.path in qa-config.json, or (no config) env QA_KEYSTORE_PATH + QA_KEYSTORE_ALIAS + QA_KEYSTORE_PASS. See references/signing.md. The patched APK is unsigned at $($patched.FullName)." }
$pass = $env:QA_KEYSTORE_PASS
if (-not $pass) { Fail "Set QA_KEYSTORE_PASS to the QA keystore password before signing." }
$zipalign = Join-Path $bt.FullName 'zipalign.exe'
$apksigner = Join-Path $bt.FullName 'apksigner.bat'
$name = [IO.Path]::GetFileNameWithoutExtension($ApkPath)
$aligned = Join-Path $OutDir "$($name)_QA_aligned.apk"
$final = Join-Path $OutDir "$($name)_QA.apk"
& $zipalign -f -p 4 $patched.FullName $aligned
& $apksigner sign --ks $ks --ks-key-alias $config.qaKeystore.alias --ks-pass "pass:$pass" --out $final $aligned
if ($LASTEXITCODE -ne 0) { Fail "apksigner failed." }
Remove-Item $aligned -Force -ErrorAction SilentlyContinue

Stage 'Done'
Write-Host "QA build: $final"
Write-Host "Push commands to QA (one line in qa_cmd.txt): coin | life | level <n> | win | noads"
