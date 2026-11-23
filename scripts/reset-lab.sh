#!/usr/bin/env bash
# Removes everything the platform and AKS stacks created in the build tenant lab, then their Terraform state, so the
# lab can be redeployed from scratch. Run by the "Lab reset" workflow (.github/workflows/lab-reset.yaml).
#
# Kept: the subscriptions, the resource groups matching PROTECTED_RG_REGEX (Terraform state storage, the plan / apply
# identities, rg-onek8s-dns with the delegated zone onek8s.lol) and the management group ROOT_MG with the bootstrap
# identities' role assignments. Everything else in the subscriptions and below ROOT_MG goes.
#
# Each pass deletes whatever it finds; a failure is retried in the next pass. The Terraform state is deleted once a
# pass finds nothing left.
#
# Environment: SUBSCRIPTIONS (space-separated), ROOT_MG, STATE_ACCOUNT, STATE_CONTAINER, PROTECTED_RG_REGEX, DRY_RUN;
# on GitHub Actions also AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID (see relogin).
set -uo pipefail

ROOT_MG="${ROOT_MG:-alz}"
DRY_RUN="${DRY_RUN:-false}"
PROTECTED_RG_REGEX="${PROTECTED_RG_REGEX:-^(rg-alz-build-|rg-onek8s-dns$)}"
STATE_BLOB_REGEX='^(terraform|platform-extensions|aks-.*)\.tfstate$'
PASSES=5
MG="/providers/Microsoft.Management/managementGroups"
ALZ_RA="Created by ALZ Terraform provider. Assignment required for Azure Policy."

# azure/login's OIDC assertion expires after minutes and errors below are swallowed, so a lapsed login would look
# like an empty lab: sign in again with a fresh GitHub OIDC token before each pass.
relogin() {
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${AZURE_CLIENT_ID:-}" ] || return 0
  local token
  token="$(curl -sSf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
    && az login --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --federated-token "$token" -o none \
    && az account set --subscription "$AZURE_SUBSCRIPTION_ID" \
    || { echo "::error::Could not sign in to Azure again."; exit 1; }
}

found=0 failed=0
del() { # <description> <command...>
  local what="$1" out; shift
  found=$((found + 1))
  if [ "$DRY_RUN" = true ]; then echo "  would delete: $what"; return 0; fi
  if out="$("$@" 2>&1)"; then echo "  deleted: $what"
  else failed=$((failed + 1)); echo "::warning::$what: $(tail -n 2 <<<"$out" | tr '\n' ' ')"; return 1; fi
}

child_mgs() { # below ROOT_MG, deepest first
  az account management-group show --name "$ROOT_MG" --expand --recurse -o json 2>/dev/null | jq -r '
    def w($d): (.children // [])[] | select(.type | endswith("managementGroups")) | ({name, d: $d}, w($d + 1));
    [w(1)] | sort_by(-.d) | .[].name'
}

pass() {
  local mgs sub scope id name rg managed kind filter where deleting=()
  mgs="$ROOT_MG $(child_mgs | tr '\n' ' ')"

  echo "::group::locks, budgets"
  for sub in $SUBSCRIPTIONS; do
    for id in $(az lock list --subscription "$sub" --query "[].id" -o tsv 2>/dev/null); do
      rg="$(sed -nE 's|.*/resourceGroups/([^/]+)/.*|\1|ip' <<<"$id")"
      [[ -n "$rg" && "$rg" =~ $PROTECTED_RG_REGEX ]] || del "lock $id" az lock delete --ids "$id"
    done
    for id in $(az rest --method get --query "value[].id" -o tsv --url \
        "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" 2>/dev/null); do
      del "budget $id" az rest --method delete --url "https://management.azure.com$id?api-version=2023-05-01"
    done
  done
  echo "::endgroup::"

  echo "::group::policy assignments, exemptions, policy role assignments"
  for scope in $(printf "$MG/%s\n" $mgs) $(printf '/subscriptions/%s\n' $SUBSCRIPTIONS); do
    for name in $(az policy assignment list --scope "$scope" --query "[?scope=='$scope'].name" -o tsv 2>/dev/null); do
      del "policy assignment $scope/$name" az policy assignment delete --scope "$scope" --name "$name"
    done
    for id in $(az policy exemption list --scope "$scope" --query "[?starts_with(id, '$scope/')].id" -o tsv 2>/dev/null); do
      del "policy exemption $id" az policy exemption delete --ids "$id"
    done
    for id in $(az role assignment list --scope "$scope" --query "[?description=='$ALZ_RA'].id" -o tsv 2>/dev/null); do
      del "role assignment $id" az role assignment delete --ids "$id"
    done
  done
  echo "::endgroup::"

  echo "::group::resource groups"
  for sub in $SUBSCRIPTIONS; do
    while IFS=$'\t' read -r rg managed; do
      [ -z "$rg" ] || [[ "$rg" =~ $PROTECTED_RG_REGEX ]] && continue
      [ -n "$managed" ] && [ "$managed" != None ] && continue # goes with its owner (AKS node resource group)
      del "resource group $sub/$rg" az group delete --subscription "$sub" -n "$rg" --yes --no-wait && deleting+=("$sub/$rg")
    done < <(az group list --subscription "$sub" --query "[].[name, managedBy]" -o tsv 2>/dev/null)
  done
  [ "$DRY_RUN" = true ] || for item in "${deleting[@]}"; do
    az group wait --subscription "${item%%/*}" -n "${item#*/}" --deleted --timeout 1800 >/dev/null 2>&1 \
      || echo "::warning::$item still being deleted"
  done
  echo "::endgroup::"

  echo "::group::custom policy (set) definitions, custom roles"
  for scope in $(printf "$MG/%s\n" $mgs) $(printf '/subscriptions/%s\n' $SUBSCRIPTIONS); do
    [[ "$scope" == "$MG"/* ]] && where=(--management-group "${scope##*/}") || where=(--subscription "${scope##*/}")
    for kind in set-definition definition; do
      for name in $(az policy $kind list "${where[@]}" \
          --query "[?policyType=='Custom' && starts_with(id, '$scope/')].name" -o tsv 2>/dev/null); do
        del "policy $kind $scope/$name" az policy $kind delete "${where[@]}" --name "$name"
      done
    done
    # custom roles: at a management group the ALZ library roles "<name> (<mg>)" (never the bootstrap identities'),
    # at a subscription those assignable only inside it
    filter='all(.assignableScopes[]; ascii_downcase | startswith($s | ascii_downcase))'
    [[ "$scope" == "$MG"/* ]] && filter='.roleName | endswith(" (" + ($s | split("/") | last) + ")")'
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] && del "custom role '$name'" az role definition delete --name "${id##*/}" --scope "$( [[ "$scope" == "$MG"/* ]] && echo "$MG/$ROOT_MG" || echo "$scope")"
    done < <(az role definition list --custom-role-only true --scope "$scope" -o json 2>/dev/null \
      | jq -r --arg s "$scope" ".[] | select($filter) | [.id, .roleName] | @tsv")
  done
  echo "::endgroup::"

  echo "::group::management groups below $ROOT_MG"
  for mg in $(child_mgs); do
    for sub in $(az account management-group subscription show-sub-under-mg --name "$mg" --query "[].name" -o tsv 2>/dev/null); do
      del "subscription $sub in $mg (moved to $ROOT_MG)" az account management-group subscription add --name "$ROOT_MG" --subscription "$sub"
    done
    del "management group $mg" az account management-group delete --name "$mg"
  done
  echo "::endgroup::"
}

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1
echo "Subscriptions: $SUBSCRIPTIONS"
echo "Kept: management group $ROOT_MG, resource groups matching $PROTECTED_RG_REGEX"

for i in $(seq 1 "$PASSES"); do
  echo "=== pass $i/$PASSES"
  found=0 failed=0
  relogin
  pass
  [ "$DRY_RUN" = true ] && { echo "Dry run: $found items; plus Terraform state matching $STATE_BLOB_REGEX"; exit 0; }
  echo "=== pass $i: $found found, $failed failed"
  [ "$found" -eq 0 ] && break
  [ "$i" -eq "$PASSES" ] && { echo "::error::Still deleting after $PASSES passes; state kept. Run the workflow again."; exit 1; }
  sleep 60
done

echo "=== Terraform state ($STATE_CONTAINER in $STATE_ACCOUNT)"
relogin
failed=0
blobs="$(az storage blob list --account-name "$STATE_ACCOUNT" -c "$STATE_CONTAINER" --auth-mode login --query "[].name" -o tsv)" \
  || { echo "::error::Could not list the state blobs."; exit 1; }
for blob in $(grep -E "$STATE_BLOB_REGEX" <<<"$blobs"); do
  az storage blob lease break --account-name "$STATE_ACCOUNT" -c "$STATE_CONTAINER" -b "$blob" --auth-mode login >/dev/null 2>&1
  del "state $blob" az storage blob delete --account-name "$STATE_ACCOUNT" -c "$STATE_CONTAINER" -n "$blob" \
    --delete-snapshots include --auth-mode login
done
[ "$failed" -eq 0 ] || { echo "::error::Could not delete every state blob."; exit 1; }
echo "Lab reset complete."
