# One-time setup

## Tools

```powershell
# Frida + objection (gadget embedding)
py -m pip install frida-tools objection

# apktool — via Scoop, or drop apktool.bat + apktool.jar on PATH
scoop install apktool
```

Android SDK build-tools (aapt, zipalign, apksigner) come with Android Studio; confirm one is on
`%LOCALAPPDATA%\Android\Sdk\build-tools\<ver>`.

Il2CppDumper is shared with the `apk-teardown` skill under `_reference/tools/`.

## Gadget download

`objection patchapk` downloads a Frida gadget matching the APK's ABI from Frida's official
GitHub releases. This needs network access; the skill asks before letting it run. The gadget is
large (~25 MB for arm64) and goes into the patched APK.

## Verify the gate before trusting it

Break it on purpose once:

```powershell
# A non-Sonat APK must be refused:
scripts/Assert-OwnedApk.ps1 -ApkPath _reference/Parking_Loop_v617_MOD.apk -ConfigPath scripts/qa-config.json -OutDir $env:TEMP/gatetest
# Expect verdict NOT_OWNED and a non-zero exit.
```

If that returns anything but `NOT_OWNED`, the gate is miswired — fix before using the skill.
