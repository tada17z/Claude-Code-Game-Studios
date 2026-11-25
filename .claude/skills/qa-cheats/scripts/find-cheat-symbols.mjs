// Scans an Il2CppDumper dump.cs for functions that likely drive QA cheats, and emits a mapping
// JSON plus a ready-to-edit Frida script built from patch-template.js.
//
// It does NOT guess what a function does from nothing: it reports candidates with the evidence
// (class, signature, RVA) and a confidence, and leaves every slot the developer must confirm
// marked "REVIEW". A slot with no candidate is written as "NOT FOUND", never silently omitted,
// so a missing hook is visible instead of looking like a disabled cheat.
//
// Usage: node find-cheat-symbols.mjs <dump.cs> <patch-template.js> <outDir>
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const [dumpPath, templatePath, outDir] = process.argv.slice(2);
if (!dumpPath || !templatePath || !outDir) {
  console.error("Usage: node find-cheat-symbols.mjs <dump.cs> <patch-template.js> <outDir>");
  process.exit(1);
}
const dump = readFileSync(dumpPath, "utf8");

// A "slot" is one cheat lever. patterns match a method's class+name; we rank by how specific.
const SLOTS = [
  { key: "addGold", desc: "Add currency (dev debug menu is ideal)", patterns: [/Earn\d*Gold/i, /Earn\d*Coin/i, /AddGold/i, /AddCoin/i, /SetGold/i] },
  { key: "getGold", desc: "Read currency balance", patterns: [/\bget_?Gold\b/i, /GetGold/i, /GetCoin/i, /get_Coins?/i] },
  { key: "consumeGold", desc: "Spend currency (hook to no-op for infinite)", patterns: [/ConsumeGold/i, /SpendGold/i, /ConsumeCoin/i, /RemoveGold/i] },
  { key: "addBooster", desc: "Grant boosters/power-ups", patterns: [/Earn\d*\w*Booster/i, /AddBooster/i, /GrantBooster/i] },
  { key: "infiniteLife", desc: "Infinite lives/energy", patterns: [/InfiniteLife/i, /InfiniteEnergy/i, /SetInfinite/i, /AddLife/i, /RefillLi(ves|fe)/i] },
  { key: "setLevel", desc: "Jump to a level/stage", patterns: [/SetCurrentLevelId/i, /SetLevel\b/i, /SetStage/i, /GoToLevel/i, /LoadLevel\b/i] },
  { key: "winLevel", desc: "Force win the current level", patterns: [/FireSuccess/i, /\bWin\b/i, /CompleteLevel/i, /LevelComplete/i, /OnWin/i] },
  { key: "adsRemoved", desc: "Report ads as removed", patterns: [/\bget_?IsAdsRemoved\b/i, /IsAdsRemoved/i, /IsNoAds/i, /HasRemovedAds/i] },
  { key: "adAvailable", desc: "Interstitial/ad availability checks", patterns: [/IsInterstitialShowAvailable/i, /Is\w*AdAvailable/i, /CanShow\w*Ad/i] },
  { key: "certValid", desc: "Signature/cert check (re-sign flips this; hook to true)", patterns: [/IsCertificate\w*Valid/i, /IsSignatureValid/i, /VerifySignature/i, /IsUsingDifferentOS/i] },
];

// Parse "// RVA: 0x... " lines paired with the following method declaration.
const lines = dump.split(/\r?\n/);
const methods = [];
let currentClass = null;
let pendingRva = null;
for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const cls = line.match(/^\s*(?:public|private|internal|protected|sealed|abstract|static|\s)*\bclass\s+([A-Za-z0-9_<>]+)/);
  if (cls) currentClass = cls[1];
  const rva = line.match(/\/\/\s*RVA:\s*(0x[0-9A-Fa-f]+)/);
  if (rva) { pendingRva = rva[1]; continue; }
  const method = line.match(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(([^;{]*)\)\s*(?:\{|;|$)/);
  if (method && pendingRva && !line.includes("class ")) {
    methods.push({ cls: currentClass, name: method[1], sig: line.trim(), rva: pendingRva });
  }
  pendingRva = null;
}

const mapping = {};
for (const slot of SLOTS) {
  const hits = methods
    .filter(m => slot.patterns.some(p => p.test(m.name) || p.test(`${m.cls}.${m.name}`)))
    .slice(0, 8)
    .map(m => ({ class: m.cls, name: m.name, rva: m.rva, signature: m.sig }));
  mapping[slot.key] = {
    description: slot.desc,
    status: hits.length ? "REVIEW" : "NOT FOUND",
    chosen: null,
    candidates: hits,
  };
}

const found = Object.values(mapping).filter(s => s.status === "REVIEW").length;
const report = {
  dump: path.resolve(dumpPath),
  slotsFound: found,
  slotsTotal: SLOTS.length,
  note: "status REVIEW = candidates found, pick one into `chosen` (the RVA). status NOT FOUND = no candidate; that cheat cannot be wired until you locate the function by hand in dump.cs.",
  mapping,
};
writeFileSync(path.join(outDir, "cheat-symbols.json"), JSON.stringify(report, null, 2));

// Emit the Frida script with the RVA table pre-filled from the single best candidate per slot,
// each marked so an unreviewed address is obvious.
const template = readFileSync(templatePath, "utf8");
const rvaLines = SLOTS.map(slot => {
  const m = mapping[slot.key];
  if (m.status === "NOT FOUND") return `    ${slot.key}: null, // NOT FOUND — locate in dump.cs by hand`;
  const best = m.candidates[0];
  return `    ${slot.key}: ${best.rva}, // REVIEW ${best.class}.${best.name} — ${m.candidates.length} candidate(s), confirm before trusting`;
}).join("\n");
const script = template.replace("/*__RVA_TABLE__*/", rvaLines);
writeFileSync(path.join(outDir, "patch.js"), script);

console.log(JSON.stringify({ slotsFound: found, slotsTotal: SLOTS.length, out: path.join(outDir, "cheat-symbols.json") }, null, 2));
if (found === 0) process.exit(2); // nothing matched: do not let "generated a script" read as "cheats ready"
