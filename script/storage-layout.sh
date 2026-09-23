#!/usr/bin/env bash
# Print SettlementVault's storage layout in a stable, diffable form.
#
# The raw `forge inspect ... storageLayout --json` output carries `astId`s that shift whenever any
# line above a variable moves, so a raw diff is noise. Slot, offset, label and type are what actually
# matter: if any of those change, storage has moved and an already-deployed vault cannot be reasoned
# about with the new source. Committed as abi/SettlementVault.storage.json and checked in CI.
set -euo pipefail
forge inspect SettlementVault storageLayout --json \
  | jq -S '{storage: [.storage[] | {label, slot, offset, type}], types: .types}'
