#!/usr/bin/env bash
# Removes ABSOLUTELY EVERYTHING from the build tenant lab - also what the Lab reset workflow keeps. Run it by hand,
# signed in with `az login` as a tenant admin (Owner on the `alz` management group and the subscriptions, and
# management group rights at the Tenant Root Group; Owner given directly on the subscriptions or at the Tenant Root
# Group, since access inherited from `alz` ends when they leave it). There is no workflow for it on purpose.
#
#   scripts/reset-lab-full.sh            # dry run (the default): lists what would be deleted
#   scripts/reset-lab-full.sh --apply    # deletes, after you type the confirmation
#
# Deleted, in the lab subscriptions and the management group tree ROOT_MG (alz) - the tree included:
#   resource locks, budgets, the subscriptions' diagnostic settings, policy assignments and exemptions, role
#   assignments made directly at these scopes (all but your own, so the run cannot lock you out), every resource group
#   (the accelerator bootstrap with the Terraform state and the plan / apply identities, and rg-onek8s-dns with
#   the public zone onek8s.lol: its name servers change when it is created again, so the registrar's NS records must
#   be updated), soft-deleted Key Vaults (purged; those with purge protection cannot be and keep their names for up
#   to 90 days), custom policy (set) definitions, custom roles assignable only inside the lab, and the management
#   groups themselves (the subscriptions are moved to the Tenant Root Group first).
# Kept: the subscriptions themselves and the GitHub configuration. Redeploying starts at docs/deployment.md, step 2
# (the accelerator bootstrap), then step 3b (DNS zone and the registrar).
#
# Environment: SUBSCRIPTIONS (space-separated; default: the subscriptions in the repository's configuration),
# ROOT_MG (alz), PASSES (5).
set -uo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=true
case "${1:-}" in
  --apply) DRY_RUN=false ;;
  "" | --dry-run) ;;
  *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac
ROOT_MG="${ROOT_MG:-alz}"
PASSES="${PASSES:-5}"
MG="/providers/Microsoft.Management/managementGroups"

az account show -o none 2>/dev/null || { echo "Sign in first: az login" >&2; exit 1; }
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1
TENANT="$(az account show --query tenantId -o tsv)"
if [ "$(az account show --query user.type -o tsv)" = servicePrincipal ]; then
  ME="$(az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv)"
else
  ME="$(az ad signed-in-user show --query id -o tsv)"
fi

if [ -z "${SUBSCRIPTIONS:-}" ]; then # as the Lab reset workflow finds them
  SUBSCRIPTIONS="$( {
    python3 -I -c 'import sys, yaml; print("\n".join(v for v in yaml.safe_load(open(sys.argv[1]))["subscription_ids"].values() if v))' \
      accelerator/config/inputs.yaml
    cat stacks/platform-extensions/terraform.tfvars environments/*/*.tfvars 2>/dev/null \
      | sed -nE 's/^ *subscription_id *= *"([0-9a-f-]{36})".*/\1/p'
  } | sort -u | tr '\n' ' ')"
fi
subs=""
for sub in $SUBSCRIPTIONS; do
  if az account show --subscription "$sub" -o none 2>/dev/null; then subs="$subs $sub"; else echo "skipped $sub (not accessible)"; fi
done
SUBSCRIPTIONS="${subs# }"
[ -n "$SUBSCRIPTIONS" ] || { echo "No accessible lab subscriptions." >&2; exit 1; }

found=0 failed=0
del() { # <description> <command...>
  local what="$1" out; shift
  found=$((found + 1))
  if [ "$DRY_RUN" = true ]; then echo "  would delete: $what"; return 0; fi
  if out="$("$@" 2>&1)"; then echo "  deleted: $what"
  else failed=$((failed + 1)); echo "  FAILED: $what: $(tail -n 2 <<<"$out" | tr '\n' ' ')"; return 1; fi
}

mgs() { # ROOT_MG and every management group below it, deepest first (none once ROOT_MG is gone)
  az account management-group show --name "$ROOT_MG" --expand --recurse -o json 2>/dev/null | jq -r '
    def w($d): {name, d: $d}, ((.children // [])[] | select(.type | endswith("managementGroups")) | w($d + 1));
    [w(0)] | sort_by(-.d) | .[].name'
}

pass() {
  local tree scopes prefixes sub scope id name rg managed kind where deleting=()
  tree="$(mgs | tr '\n' ' ')"
  scopes="$(printf "$MG/%s\n" $tree; printf '/subscriptions/%s\n' $SUBSCRIPTIONS)"
  prefixes="$(jq -Rnc '[inputs | ascii_downcase]' <<<"$scopes")"
  for sub in $SUBSCRIPTIONS; do # an unreadable subscription would look empty, i.e. done
    az group list --subscription "$sub" -o none 2>/dev/null || {
      echo "Cannot read subscription $sub any more. If your access came from the $ROOT_MG management group, it ended" \
        "when the subscription left it: assign yourself Owner on the subscription (or at the Tenant Root Group) and" \
        "run the script again." >&2
      exit 1
    }
  done

  echo "--- locks, budgets, subscription diagnostic settings"
  for sub in $SUBSCRIPTIONS; do
    for id in $(az lock list --subscription "$sub" --query "[].id" -o tsv 2>/dev/null); do
      del "lock $id" az lock delete --ids "$id"
    done
    for id in $(az rest --method get --query "value[].id" -o tsv --url \
        "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" 2>/dev/null); do
      del "budget $id" az rest --method delete --url "https://management.azure.com$id?api-version=2023-05-01"
    done
    for name in $(az monitor diagnostic-settings subscription list --subscription "$sub" --query "value[].name" -o tsv 2>/dev/null); do
      del "diagnostic setting $sub/$name" az monitor diagnostic-settings subscription delete --subscription "$sub" --name "$name" --yes
    done
  done

  echo "--- policy assignments, exemptions, role assignments"
  for scope in $scopes; do
    for name in $(az policy assignment list --scope "$scope" --query "[?scope=='$scope'].name" -o tsv 2>/dev/null); do
      del "policy assignment $scope/$name" az policy assignment delete --scope "$scope" --name "$name"
    done
    for id in $(az policy exemption list --scope "$scope" --query "[?starts_with(id, '$scope/')].id" -o tsv 2>/dev/null); do
      del "policy exemption $id" az policy exemption delete --ids "$id"
    done
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] && del "role assignment $scope: $name" az role assignment delete --ids "$id"
    done < <(az role assignment list --scope "$scope" -o json 2>/dev/null | jq -r --arg s "$scope" --arg me "$ME" \
      '.[] | select((.scope | ascii_downcase) == ($s | ascii_downcase) and .principalId != $me)
           | [.id, "\(.roleDefinitionName) for \(.principalName // .principalId)"] | @tsv')
  done

  echo "--- resource groups"
  for sub in $SUBSCRIPTIONS; do
    while IFS=$'\t' read -r rg managed; do
      [ -z "$rg" ] && continue
      [ -n "$managed" ] && [ "$managed" != None ] && continue # goes with its owner (AKS node resource group)
      del "resource group $sub/$rg" az group delete --subscription "$sub" -n "$rg" --yes --no-wait && deleting+=("$sub/$rg")
    done < <(az group list --subscription "$sub" --query "[].[name, managedBy]" -o tsv 2>/dev/null)
  done
  [ "$DRY_RUN" = true ] || for item in "${deleting[@]}"; do
    echo "  waiting for $item"
    az group wait --subscription "${item%%/*}" -n "${item#*/}" --deleted --timeout 3600 >/dev/null 2>&1 \
      || echo "  $item is still being deleted"
  done

  echo "--- soft-deleted Key Vaults"
  for sub in $SUBSCRIPTIONS; do
    while IFS=$'\t' read -r name protected; do
      [ -z "$name" ] && continue
      [ "$protected" = true ] && { echo "  kept: $name (purge protection, gone when its retention ends)"; continue; }
      del "soft-deleted Key Vault $name" az keyvault purge --subscription "$sub" --name "$name"
    done < <(az keyvault list-deleted --subscription "$sub" --resource-type vault \
      --query "[].[name, properties.purgeProtectionEnabled]" -o tsv 2>/dev/null)
  done

  echo "--- custom policy (set) definitions, custom roles"
  for scope in $scopes; do
    [[ "$scope" == "$MG"/* ]] && where=(--management-group "${scope##*/}") || where=(--subscription "${scope##*/}")
    for kind in set-definition definition; do
      for name in $(az policy $kind list "${where[@]}" \
          --query "[?policyType=='Custom' && starts_with(id, '$scope/')].name" -o tsv 2>/dev/null); do
        del "policy $kind $scope/$name" az policy $kind delete "${where[@]}" --name "$name"
      done
    done
  done
  while IFS=$'\t' read -r id scope name; do # every custom role whose assignable scopes all lie inside the lab
    [ -n "$id" ] && del "custom role '$name'" az role definition delete --name "${id##*/}" --scope "$scope"
  done < <(for scope in $scopes; do az role definition list --custom-role-only true --scope "$scope" -o json 2>/dev/null; done \
    | jq -rs --argjson p "$prefixes" 'add // [] | unique_by(.name)[]
        | select(all(.assignableScopes[] | ascii_downcase; . as $x | any($p[]; $x == . or ($x | startswith(. + "/")))))
        | [.id, .assignableScopes[0], .roleName] | @tsv')

  echo "--- management groups ($ROOT_MG and below)"
  for mg in $tree; do
    for sub in $(az account management-group subscription show-sub-under-mg --name "$mg" --query "[].name" -o tsv 2>/dev/null); do
      del "subscription $sub in $mg (moved to the Tenant Root Group)" \
        az account management-group subscription add --name "$TENANT" --subscription "$sub"
    done
    del "management group $mg" az account management-group delete --name "$mg"
  done
}

echo "Signed in to tenant $TENANT as $(az account show --query user.name -o tsv) (your own role assignments stay)"
echo "Subscriptions: $SUBSCRIPTIONS"
echo "Management groups: $ROOT_MG and everything below it"

if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN - nothing is deleted"
  pass
  echo "=== dry run: $found items would be deleted; run with --apply to delete them"
  exit 0
fi

echo
echo "This deletes EVERYTHING listed above, including the bootstrap, the Terraform state and the public DNS zone."
read -r -p "Type 'delete-everything' to continue: " answer
[ "$answer" = delete-everything ] || { echo "Aborted."; exit 1; }

for i in $(seq 1 "$PASSES"); do
  echo "=== pass $i/$PASSES"
  found=0 failed=0
  pass
  echo "=== pass $i: $found found, $failed failed"
  [ "$found" -eq 0 ] && { echo "Lab fully removed."; exit 0; }
  [ "$i" -lt "$PASSES" ] && sleep 60
done
echo "Something is still left after $PASSES passes (see above); run the script again." >&2
exit 1
