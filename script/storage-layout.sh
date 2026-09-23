#!/usr/bin/env bash
# Print SettlementVault's storage layout in a stable, diffable form.
#
# Three kinds of noise are stripped, because a check that cries wolf gets ignored:
#   - `astId` on each storage entry, which shifts whenever any line above a variable moves;
#   - `astId` on every struct member inside `types`, which shifts for the same reason -- and also
#     when the same source is compiled under a different profile;
#   - the AST id baked into struct and enum type identifiers, e.g. `t_struct(RoleData)22_storage`.
# What is left -- slot, offset, label, and the shape and size of every type -- is the part that
# matters. If any of it changes, storage has moved: the vault is not upgradeable, so that is a
# redeploy, not a migration. Committed as abi/SettlementVault.storage.json and diffed in CI.
#
# `extra_output = ["storageLayout"]` in foundry.toml keeps this working off a cached build.
set -euo pipefail
forge build >/dev/null
forge inspect SettlementVault storageLayout --json \
  | jq -S '
      def strip_ast: gsub("(?<k>t_(struct|enum)\\([A-Za-z0-9_]+\\))[0-9]+"; .k);
      {storage: [.storage[] | {label, slot, offset, type}], types: .types}
      | walk(if type == "object" then del(.astId)
             elif type == "string" then strip_ast
             else . end)
      | .types |= with_entries(.key |= strip_ast)
    '
