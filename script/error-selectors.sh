#!/usr/bin/env bash
# Emit the 4-byte selector -> signature map for every custom error the vault can revert with.
#
# Issue #29. Clients (the Rust backend, the frontend decoder, the monitor) see reverts as four
# opaque bytes. Without this map a new or changed error shows up in production as an unexplained
# hex code. Generated from the built ABI, so it cannot drift from the contract; CI diffs it the
# same way it diffs the ABI itself.
set -euo pipefail
forge inspect SettlementVault abi --json \
  | jq -S 'map(select(.type == "error"))
           | map({sig: (.name + "(" + ([.inputs[].type] | join(",")) + ")")})
           | map({(.sig): .sig}) | add' > /tmp/kimana-error-sigs.json

jq -r 'keys[]' /tmp/kimana-error-sigs.json | while read -r sig; do
  printf '%s\t%s\n' "$(cast sig "$sig")" "$sig"
done | jq -R -s -S 'split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): .[1]}) | add'
