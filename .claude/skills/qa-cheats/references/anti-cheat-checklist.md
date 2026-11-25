# Anti-cheat checklist for Sonat games

Derived from the Parking Loop mod teardown. Each item is something that mod exploited; fixing it
in Sonat games closes that class of cheat. Order is by revenue impact.

## Must (protects revenue)

- [ ] **Rewarded ads verified server-side.** Use the ad network's server-side verification
  callback (AdMob SSV, IronSource/AppLovin equivalents). The client must never grant a reward by
  itself — the Parking Loop class of "skip ad, keep reward" dies here.
- [ ] **Currency and purchases authoritative on the server.** Client shows balances; server owns
  them. Validate Play Billing purchases server-side. Do not trust a local "coins" or
  "ads removed" value.
- [ ] **Strip the debug/cheat menu from release.** The mod called the game's own
  `SROptions_User.Earn100000Gold`, `LifeController.InfiniteLife`, `GameplaySceneController.FireSuccess`
  — all shipped in the release build. Gate cheat code behind a compile flag and verify it is
  absent from the store build (a build-time check that greps the release for the cheat symbols).

## Should (raises the cost of modding)

- [ ] **Play Integrity API** on sensitive actions (rewards, purchases, leaderboard writes). A
  re-signed/Frida-patched build fails the strong verdict.
- [ ] **App signature self-check** done server-side or in native code, not a single client bool.
  The mod simply hooked `IsCertificateSHA1FingerprintValid` → true. A check that only flips one
  return value is one hook away from defeat; tie the result into a server call.
- [ ] **Keep ObscuredInt / anti-cheat (CodeStage) for offline values** — it forced the mod to
  avoid direct memory writes. Useful friction, but not a substitute for server authority.

## Nice (slows automated tools)

- [ ] **Encrypt `global-metadata.dat`** (or use a packer) so Il2CppDumper cannot recover symbol
  names and addresses — this is what makes the automated cheat-symbol scan fail.
- [ ] **Detect Frida gadget** (scan loaded modules / maps for the gadget and known ports). Not
  foolproof, but removes the easiest embed path.
- [ ] Prefer **IL2CPP over Mono** for release (Mono's `Assembly-CSharp.dll` decompiles cleanly).
