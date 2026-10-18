#!/usr/bin/env bash
# Fails if a transceiver declares a selector that a TransceiverExtension also declares under a
# different signature. Run from contracts/evm after `forge build`; CI runs it.
#
# A transceiver runs every selector it does not declare in its extension (#70). Solidity
# refuses a selector clash inside one contract, but not across the two: a provider function
# whose selector equals an extension function's would answer first, so the extension function
# would be unreachable and a call meant for it would run the provider's code. The same
# signature in both is the same function, inherited from TransceiverCore, and is allowed.
#
# Discovery is by ABI, not by name, so a new provider's transceiver is checked without editing
# this file: a transceiver is any deployable contract under src/ declaring `extension()`, an
# extension any declaring `initializeBase(...)`. Each transceiver is checked against every
# extension variant, since its pairing is a constructor argument the artifacts do not record.
set -euo pipefail

out="${1:-out}"
shopt -s nullglob
artifacts=("$out"/*.sol/*.json)
if [ ${#artifacts[@]} -eq 0 ]; then
  echo "check-selectors: no artifacts under $out; run forge build first" >&2
  exit 1
fi

report=$(jq -n -r '
  [inputs
    | select((.metadata.settings.compilationTarget // {} | keys | first // "") | startswith("src/"))
    | select((.bytecode.object // "0x") | length > 2)
    | {name: (.metadata.settings.compilationTarget | to_entries | first | .value),
       ids: (.methodIdentifiers // {} | to_entries | map({sig: .key, sel: .value}))}] as $all
  | [$all[] | select(any(.ids[]; .sig == "extension()"))] as $mains
  | [$all[] | select(any(.ids[]; .sig | startswith("initializeBase(")))] as $exts
  | "counts \($mains | length) \($exts | length)",
    ($mains[] as $m | $m.ids[] as $f | $exts[] as $e | $e.ids[]
      | select(.sel == $f.sel and .sig != $f.sig)
      | "clash \($m.name).\($f.sig) and \($e.name).\(.sig) share 0x\(.sel)")
' "${artifacts[@]}")

read -r _ mains exts <<<"$(grep '^counts ' <<<"$report")"
if [ "$mains" -eq 0 ] || [ "$exts" -eq 0 ]; then
  echo "check-selectors: found $mains transceivers and $exts extensions; expected some of each" >&2
  exit 1
fi

if grep -q '^clash ' <<<"$report"; then
  grep '^clash ' <<<"$report" | sed 's/^clash /check-selectors: /' >&2
  exit 1
fi
echo "check-selectors: $mains transceivers, $exts extensions, no selector clash"
