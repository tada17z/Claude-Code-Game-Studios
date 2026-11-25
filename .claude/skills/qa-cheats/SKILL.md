---
name: qa-cheats
description: "Builds a QA cheat version of a Sonat Unity IL2CPP game from an APK: coin/life/level-skip/no-ads toggles via an embedded Frida gadget, re-signed with a QA key. Only runs on APKs confirmed to belong to Sonat (package-prefix + optional signing-cert gate); refuses any other game. Use when QA needs to play a Sonat build quickly without grinding. For a competitor's APK, use apk-teardown instead."
argument-hint: "<path to Sonat .apk> [outDir]"
user-invocable: true
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, PowerShell
---

# QA Cheats (Sonat builds only)

Turns a **Sonat** Unity IL2CPP APK into a QA build with in-app cheats (coins, lives, level
skip, force-win, no ads), driven by an embedded Frida gadget. The point is QA speed: play any
state without grinding. It mirrors how a public mod works (see
`_reference/` Parking Loop teardown), but limited to apps Sonat owns and signed with a QA key.

## Hard boundary — read first

- **Only Sonat's own apps.** Phase 1 is an ownership gate. If the APK's package does not match
  `ownedPackagePrefixes` in `qa-config.json` (and `ownedCertSha256` if set), the skill **stops**
  and does nothing. Do not edit the gate to pass another company's app, and do not run this on a
  competitor APK (e.g. `com.loop.packedloop`). For those, `/apk-teardown` + the web prototype is
  the QA path, and it does not modify anyone's APK.
- **QA only.** The output is renamed (`appLabelSuffix`) and signed with a **QA** key, never the
  Play release key. It is for internal testing on QA devices/emulators, not for distribution.
- If source exists, cheats belong in the source behind `#if SONAT_CHEAT` — more stable than
  patching a built APK. Use this skill when only the APK is available.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| Il2CppDumper | find cheat function addresses | shared `_reference/tools/` (see apk-teardown) |
| Android build-tools (aapt, zipalign, apksigner) | read package, align, sign | Android SDK |
| apktool, objection (+ frida-tools) | embed the gadget | `py -m pip install objection frida-tools`; apktool via Scoop/jar |
| Node 18+ | symbol scan | PATH |

If a tool is missing the build **stops and names it** rather than producing a half-built APK.
Ask the user before installing anything or letting objection download a Frida gadget.

## Phase 0 — Config

1. `qa-config.json` in `scripts/` is **optional**. Absent ⇒ ownership gate skipped (see Phase 1).
   To enable the gate, copy `qa-config.example.json`; it then needs at least one
   `ownedPackagePrefixes` entry (an empty list refuses everything, fail closed).
2. Recommend setting `ownedCertSha256` — prefix match alone is spoofable. Get it with
   `keytool -list -printcert -jarfile <apk>`.
3. A QA keystore (`qaKeystore.path`, alias, and `QA_KEYSTORE_PASS` env var). Generate one per
   `references/signing.md`. Never the release key.

## Phase 1 — Ownership gate

```powershell
.claude/skills/qa-cheats/scripts/Assert-OwnedApk.ps1 -ApkPath <apk> -ConfigPath <cfg> -OutDir <out>
```

Reads `ownership.json`. Verdicts: `OWNED` (proceed), `GATE_SKIPPED` (proceed, unverified — see
below), `NOT_OWNED` / `CERT_MISMATCH` (stop — not Sonat's), `CANNOT_ASSESS` (stop — config/tools
incomplete). Any stop verdict exits non-zero, so a caller that ignores the text still halts.

**No `qa-config.json` (gitignored, per-dev) ⇒ the gate is skipped and the skill runs straight
through.** This is a deliberate choice, not a pass: the verdict is `GATE_SKIPPED`, a warning is
printed, and `ownership.json` records that the package was unverified. Report it as "ownership
NOT verified" — never as `OWNED`. Once a `qa-config.json` exists the gate runs in full (and still
fails closed on an empty prefix list). Without a config, the QA keystore comes from env vars
`QA_KEYSTORE_PATH`, `QA_KEYSTORE_ALIAS`, `QA_KEYSTORE_PASS`. The "Sonat only" rule still applies:
the skill is for Sonat builds even when the check is off.

## Phase 2–5 — Build

```powershell
.claude/skills/qa-cheats/scripts/Build-QaApk.ps1 -ApkPath <apk>
```

Runs: gate → tool check → engine check (IL2CPP required) → `Il2CppDumper` → `find-cheat-symbols`.
It then **stops** and asks you to review `cheat-symbols.json` and `patch.js`, because the cheat
functions are game-specific and candidate addresses must be confirmed (a wrong RVA crashes the
app). Each cheat slot is `REVIEW` (candidates found, pick one) or `NOT FOUND` (locate by hand);
a `NOT FOUND` slot is written as such, never left looking like a working-but-off cheat.

## Phase 6 — Confirm and finish

After mapping the symbols, re-run with `-AssumeYes`. It embeds the Frida gadget + `patch.js` with
`objection patchapk`, zipaligns, and signs with the QA key → `<name>_QA.apk`.

## Phase 7 — Use

QA drives cheats by writing one line to
`/storage/emulated/0/Android/data/<pkg>/files/qa_cmd.txt` (adb, no root):
`coin` · `life` · `level <n>` · `win` · `noads`. Logs go to `qa.log` beside it. Wire a hidden
in-app gesture to those commands if QA should not need adb (see `references/menu.md`).

## Why each cheat works (and what it implies for Sonat's own hardening)

The same lesson as the Parking Loop mod: these cheats work because the client decides things the
server should. Note this in any report so the game teams fix it:
- no-ads / rewarded-ad grants verified **server-side**, not from a client flag;
- currency and purchases authoritative on the server, with Play Billing validation;
- the dev **debug/cheat menu stripped from release** builds (the Parking Loop mod called the
  game's own `SROptions` debug functions that shipped in release);
- Play Integrity + app-signature check for sensitive features.
See `references/anti-cheat-checklist.md`.
