// Builds the publishable tree under npm/: every src/ file whose imports stay within src/,
// OpenZeppelin, and the guard, rewritten to relative imports, plus the ABIs of what it ships.
// Run after `forge build`, from contracts/evm.
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, normalize, posix, relative } from "node:path";

const root = process.cwd();
const outDir = join(root, "npm");

// Imports the consumer resolves: OpenZeppelin is a peer dependency, so one copy serves the tree.
const peerPrefixes = ["@openzeppelin/contracts/", "@openzeppelin/contracts-upgradeable/"];
// Bundled roots: package path -> repo path. The guard lives beside evm/ once it is merged.
const bundled = [
  { prefix: "src/", from: "src/", to: "" },
  { prefix: "@crossecute/safe-guard/", from: "../safe-guard/src/", to: "safe-guard/" },
].filter((b) => existsSync(join(root, b.from)));

const importRe = /^(\s*import\s+(?:[^"']*\s+from\s+)?)["']([^"']+)["'];/gm;

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".sol") ? [p] : [];
  });
}

// Repo-relative path of a source file -> its path inside the package.
function packagePath(repoPath) {
  for (const b of bundled) {
    const from = normalize(b.from);
    if (repoPath.startsWith(from)) return posix.join(b.to, repoPath.slice(from.length));
  }
  return null;
}

// An import as written in `file` -> { repo } for a bundled file, { peer } for a peer, or null.
function resolve(file, spec) {
  if (peerPrefixes.some((p) => spec.startsWith(p))) return { peer: spec };
  if (spec.startsWith(".")) return { repo: normalize(join(dirname(file), spec)) };
  const b = bundled.find((x) => spec.startsWith(x.prefix));
  return b ? { repo: normalize(b.from + spec.slice(b.prefix.length)) } : null;
}

const files = new Map();
for (const b of bundled) {
  for (const abs of walk(join(root, b.from))) {
    const repo = relative(root, abs);
    const text = readFileSync(abs, "utf8");
    const imports = [...text.matchAll(importRe)].map((m) => ({ spec: m[2], to: resolve(repo, m[2]) }));
    files.set(repo, { text, imports });
  }
}

// A file ships only if everything it reaches ships, so drop files until that holds.
const shipped = new Set(files.keys());
for (let changed = true; changed; ) {
  changed = false;
  for (const repo of shipped) {
    const ok = files.get(repo).imports.every((i) => i.to && (i.to.peer || shipped.has(i.to.repo)));
    if (!ok) {
      shipped.delete(repo);
      changed = true;
    }
  }
}

rmSync(join(outDir, "contracts"), { recursive: true, force: true });
rmSync(join(outDir, "abi"), { recursive: true, force: true });

for (const repo of [...shipped].sort()) {
  const pkg = packagePath(repo);
  const text = files.get(repo).text.replace(importRe, (whole, head, spec) => {
    const to = resolve(repo, spec);
    if (to.peer) return whole;
    let rel = posix.relative(posix.dirname(pkg), packagePath(to.repo));
    if (!rel.startsWith(".")) rel = "./" + rel;
    return `${head}"${rel}";`;
  });
  const dest = join(outDir, "contracts", pkg);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, text);
}

// ABIs keyed by contract name, taken only from artifacts whose compilation target ships.
const abis = new Map();
for (const dir of readdirSync(join(root, "out"))) {
  const artifactDir = join(root, "out", dir);
  if (!statSync(artifactDir).isDirectory()) continue;
  for (const name of readdirSync(artifactDir)) {
    if (!name.endsWith(".json")) continue;
    const artifact = JSON.parse(readFileSync(join(artifactDir, name), "utf8"));
    const target = artifact.metadata?.settings?.compilationTarget ?? {};
    for (const [source, contract] of Object.entries(target)) {
      // forge records sources outside the project root by absolute path.
      const repo = isAbsolute(source) ? relative(root, source) : normalize(source);
      if (!shipped.has(repo) || artifact.abi.length === 0) continue;
      if (abis.has(contract) && abis.get(contract).source !== repo) {
        throw new Error(`two shipped contracts are named ${contract}`);
      }
      abis.set(contract, { source: repo, abi: artifact.abi });
    }
  }
}

mkdirSync(join(outDir, "abi"), { recursive: true });
const names = [...abis.keys()].sort();
let js = "";
let dts = "";
for (const name of names) {
  const json = JSON.stringify(abis.get(name).abi);
  writeFileSync(join(outDir, "abi", `${name}.json`), json + "\n");
  js += `export const ${name}Abi = ${json};\n`;
  // A JSON literal is also a valid type literal, which keeps viem's ABI inference.
  dts += `export declare const ${name}Abi: ${json};\n`;
}
writeFileSync(join(outDir, "abi", "index.js"), js);
writeFileSync(join(outDir, "abi", "index.d.ts"), dts);

const dropped = [...files.keys()].filter((f) => !shipped.has(f)).sort();
console.log(`shipped ${shipped.size} sources and ${names.length} ABIs; left out ${dropped.length}:`);
for (const f of dropped) console.log(`  ${f}`);
