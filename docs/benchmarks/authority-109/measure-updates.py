#!/usr/bin/env python3
"""Measure current authority operations without replacing the historical verifier results."""
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
FORGE = os.environ.get("FORGE", "forge")


def run(project, pattern, log):
    result = subprocess.run(
        [FORGE, "test", "--match-test", pattern, "-vv"],
        cwd=ROOT / "contracts" / project,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    (OUT / log).write_text(result.stdout)
    result.check_returncode()
    cases = {}
    current = None
    for line in result.stdout.splitlines():
        match = re.match(r"\[PASS\] (test_\w+)\(", line)
        if match:
            current = cases.setdefault(match[1], {})
        metric = re.match(r"\s+([A-Za-z]+): (\d+)$", line)
        if metric and current is not None:
            current[metric[1]] = int(metric[2])
    return cases


def source_hashes():
    files = sorted((ROOT / "contracts/evm/src/messaging/authority").glob("*.sol"))
    files += [ROOT / path for path in [
        "contracts/evm/src/messaging/inbound/SignedReceiver.sol",
        "contracts/safe-guard/src/CrossecuteGuard.sol",
        "contracts/safe-guard/src/authority/SourceAuthorityGuard.sol",
        "contracts/evm/test/signed/SignedReceiver.t.sol",
        "contracts/safe-guard/test/SignedDispatchIntegration.t.sol",
    ]]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


before = source_hashes()
source = run("safe-guard", "test_measureAuthority", "updates-guard.log")
receiver = run("evm", "test_measureAuthorityReceiverOwnerRotation|test_batchCatchUpSharesProviderReplayState", "updates-evm.log")
assert len(source) == 5 and len(receiver) == 2, "measurement cases changed"
rows = []
for name, values in sorted(source.items()):
    rows.append(["source-cancun", name, values["authoritySourceBatchGas"],
                 values["authoritySourceBatchCalldataBytes"], values["authoritySubmissionBytes"],
                 values["authorityProviderBytes"]])
for name, prefix, gas in [
    ("test_batchCatchUpSharesProviderReplayState", "authorityReceiverBatchTwoSelection", "authorityReceiverBatchTwoSelectionGas"),
    ("test_measureAuthorityReceiverOwnerRotation", "authorityReceiverDirect", "authorityReceiverOwnerRotationGas"),
]:
    values = receiver[name]
    rows.append(["receiver-paris", name, values[gas], values[prefix + "CalldataBytes"], "", ""])
assert before == source_hashes(), "source files changed while measurements ran"
with (OUT / "updates.csv").open("w", newline="") as output:
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["scope", "case", "measured_gas", "calldata_bytes", "submission_bytes", "provider_bytes"])
    writer.writerows(rows)
manifest = {
    "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "forge": subprocess.check_output([FORGE, "--version"], text=True).splitlines()[0],
    "sha256": before,
}
(OUT / "updates-sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Measured {len(rows)} authority operations; wrote updates.csv and source hashes.")
