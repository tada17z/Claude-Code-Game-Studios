# QA signing key

The QA build is signed with a **throwaway QA key**, never the Play release key. A QA-signed APK
cannot update a store install and will not pass Play Integrity — that is intended: it keeps QA
builds separable from production.

## Generate once

```powershell
keytool -genkeypair -v -keystore qa.keystore -alias qa -keyalg RSA -keysize 2048 -validity 7300 -storepass <pass> -keypass <pass> -dname "CN=Sonat QA, O=Sonat"
```

Put the path in `qa-config.json` → `qaKeystore.path`, alias `qa`. Supply the password at build
time via the `QA_KEYSTORE_PASS` environment variable (not stored in the config):

```powershell
$env:QA_KEYSTORE_PASS = "<pass>"
```

Keep `qa.keystore` out of git (it is covered by `*.keystore`/secrets ignores; confirm).

## Get an APK's cert fingerprint (for the ownership gate)

```powershell
keytool -list -printcert -jarfile <app>.apk
```

Copy the SHA-256 into `qa-config.json` → `ownedCertSha256` so the gate checks the real signer,
not just the package name.
