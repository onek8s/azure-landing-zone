#!/usr/bin/env bash
# Removes everything inside the lab tenant LAB_TENANT, which you must be signed in to with `az login` (the script
# refuses to run in any other tenant): every enabled subscription of the tenant you can see and every management
# group, all read from Azure. The subscriptions and the management group hierarchy themselves stay untouched: nothing
# is moved and no management group is deleted. Run it by hand as a tenant admin (Owner at the Tenant Root Group).
#
#   reset-lab-full.sh            # dry run (the default): lists what would be deleted
#   reset-lab-full.sh --apply    # deletes, after you type the tenant ID
#
# Deleted, at the Tenant Root Group, every management group below it and every subscription: resource locks,
# budgets, subscription diagnostic settings, policy assignments and exemptions, role assignments made directly at
# these scopes (all but your own, so the run cannot lock you out), every resource group, soft-deleted Key Vaults
# (purged; those with purge protection cannot be and keep their names until their retention ends), custom policy
# (set) definitions and custom roles. Kept: the management groups and the subscriptions (with their placement in the
# hierarchy), your own role assignments and Azure's own system
# policy assignments (`sys.*`, e.g. sys.mfa-write / sys.mfa-delete: Microsoft-managed, nobody in the tenant can
# delete them).
#
# Environment: PASSES (5).
set -uo pipefail

START=$SECONDS
log() { printf '%s [%4ds] %s\n' "$(date +%H:%M:%S)" $((SECONDS - START)) "$*"; } # time, elapsed, message

# Safety check: the only tenant this script may empty (the OneK8s build tenant lab).
LAB_TENANT="c7496d01-3dde-45a1-9cda-11cc2f3edace"
log "checking the az login tenant"
az account show -o none 2>/dev/null || { echo "Sign in first: az login --tenant $LAB_TENANT" >&2; exit 1; }
TENANT="$(az account show --query tenantId -o tsv)"
if [ "$TENANT" != "$LAB_TENANT" ]; then
  echo "Refusing to run: signed in to tenant '$TENANT', not the lab tenant $LAB_TENANT." >&2
  echo "Run: az login --tenant $LAB_TENANT" >&2
  exit 1
fi

DRY_RUN=true
case "${1:-}" in
  --apply) DRY_RUN=false ;;
  "" | --dry-run) ;;
  *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac
PASSES="${PASSES:-5}"
MG="/providers/Microsoft.Management/managementGroups"

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1
log "looking up your own identity (its role assignments are kept)"
if [ "$(az account show --query user.type -o tsv)" = servicePrincipal ]; then
  ME="$(az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv)"
else
  ME="$(az ad signed-in-user show --query id -o tsv)"
fi
log "listing the tenant's subscriptions"
az account list --refresh -o none 2>/dev/null
declare -A SUB_NAME
while IFS=$'\t' read -r id name; do [ -n "$id" ] && SUB_NAME[$id]="$name"; done \
  < <(az account list --query "[?tenantId=='$TENANT' && state=='Enabled'].[id, name]" -o tsv)
SUBSCRIPTIONS="${!SUB_NAME[*]}"
[ -n "$SUBSCRIPTIONS" ] || { echo "No enabled subscriptions in tenant $TENANT." >&2; exit 1; }
label() { # a scope as a person reads it
  case "$1" in
    "$MG/$TENANT") echo "Tenant Root Group" ;;
    "$MG"/*) echo "management group ${1##*/}" ;;
    /subscriptions/*) echo "subscription ${SUB_NAME[${1##*/}]:-${1##*/}}" ;;
    *) echo "subscription ${SUB_NAME[$1]:-$1}" ;;
  esac
}
log "checking access to the Tenant Root Group"
az account management-group show --name "$TENANT" -o none >/dev/null 2>&1 \
  || { echo "Cannot read the Tenant Root Group: elevate access (Owner at the Tenant Root Group) first." >&2; exit 1; }

found=0 failed=0
del() { # <description> <command...>
  local what="$1" out; shift
  found=$((found + 1))
  if [ "$DRY_RUN" = true ]; then echo "  would delete: $what"; return 0; fi
  if out="$("$@" 2>&1)"; then echo "  deleted: $what"
  else failed=$((failed + 1)); echo "  FAILED: $what: $(tail -n 2 <<<"$out" | tr '\n' ' ')"; return 1; fi
}

mgs() { # every management group below the Tenant Root Group
  az account management-group show --name "$TENANT" --expand --recurse -o json 2>/dev/null | jq -r '
    def w($d): (.children // [])[] | select(.type | endswith("managementGroups")) | ({name, d: $d}, w($d + 1));
    [w(1)] | sort_by(-.d) | .[].name' 
}

step_found=0
step() { # <title>: closes the previous step with its count, opens the next one
  [ -n "${step_title:-}" ] && log "    $((found - step_found)) found in: $step_title"
  step_title="$1" step_found=$found
  [ -n "$1" ] && log "--- $1"
}

pass() {
  local tree scopes prefixes sub scope id name rg managed kind where t deleting=()
  log "reading the management group tree (kept; only what is assigned or defined at it goes)"
  tree="$(mgs | tr '\n' ' ')"
  log "  $(wc -w <<<"$tree") management groups below the Tenant Root Group, $(wc -w <<<"$SUBSCRIPTIONS") subscriptions"
  scopes="$(printf "$MG/%s\n" "$TENANT" $tree; printf '/subscriptions/%s\n' $SUBSCRIPTIONS)"
  prefixes="$(jq -Rnc '[inputs | ascii_downcase]' <<<"$scopes")"
  log "checking access to the subscriptions"
  for sub in $SUBSCRIPTIONS; do # an unreadable subscription would look empty, i.e. done
    az group list --subscription "$sub" -o none >/dev/null 2>&1 || {
      echo "Cannot read subscription $sub any more: give yourself Owner at the Tenant Root Group and run again." >&2
      exit 1
    }
  done

  step "locks, budgets, subscription diagnostic settings"
  for sub in $SUBSCRIPTIONS; do
    log "  scanning $(label "$sub")"
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

  step "policy assignments, exemptions, role assignments"
  for scope in $scopes; do
    log "  scanning $(label "$scope")"
    for name in $(az policy assignment list --scope "$scope" --query "[?scope=='$scope' && !starts_with(name, 'sys.')].name" -o tsv 2>/dev/null); do
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

  step "resource groups"
  for sub in $SUBSCRIPTIONS; do
    log "  scanning $(label "$sub")"
    while IFS=$'\t' read -r rg managed; do
      [ -z "$rg" ] && continue
      [ -n "$managed" ] && [ "$managed" != None ] && { echo "  later: $rg (goes with its owner)"; continue; }
      del "resource group $rg in $(label "$sub")" az group delete --subscription "$sub" -n "$rg" --yes --no-wait && deleting+=("$sub/$rg")
    done < <(az group list --subscription "$sub" --query "[].[name, managedBy]" -o tsv 2>/dev/null)
  done
  [ "$DRY_RUN" = true ] || [ ${#deleting[@]} -eq 0 ] \
    || log "  waiting for ${#deleting[@]} resource groups to be deleted (they are deleted in parallel; up to an hour each)"
  [ "$DRY_RUN" = true ] || for item in "${deleting[@]}"; do
    t=$SECONDS
    log "  waiting for $(label "${item%%/*}") / ${item#*/}"
    if az group wait --subscription "${item%%/*}" -n "${item#*/}" --deleted --timeout 3600 >/dev/null 2>&1; then
      log "    gone after $((SECONDS - t))s"
    else
      log "    still being deleted after $((SECONDS - t))s, checked again in the next pass"
    fi
  done

  step "soft-deleted Key Vaults"
  for sub in $SUBSCRIPTIONS; do
    log "  scanning $(label "$sub")"
    while IFS=$'\t' read -r name protected; do
      [ -z "$name" ] && continue
      [ "$protected" = true ] && { echo "  kept: $name (purge protection, gone when its retention ends)"; continue; }
      del "soft-deleted Key Vault $name" az keyvault purge --subscription "$sub" --name "$name"
    done < <(az keyvault list-deleted --subscription "$sub" --resource-type vault \
      --query "[].[name, properties.purgeProtectionEnabled]" -o tsv 2>/dev/null)
  done

  step "custom policy (set) definitions, custom roles"
  for scope in $scopes; do
    log "  scanning $(label "$scope") for policy definitions"
    [[ "$scope" == "$MG"/* ]] && where=(--management-group "${scope##*/}") || where=(--subscription "${scope##*/}")
    for kind in set-definition definition; do
      for name in $(az policy $kind list "${where[@]}" \
          --query "[?policyType=='Custom' && starts_with(id, '$scope/')].name" -o tsv 2>/dev/null); do
        del "policy $kind $scope/$name" az policy $kind delete "${where[@]}" --name "$name"
      done
    done
  done
  log "  scanning every scope for custom roles"
  while IFS=$'\t' read -r id scope name; do # every custom role whose assignable scopes all lie in this tenant
    [ -n "$id" ] && del "custom role '$name'" az role definition delete --name "${id##*/}" --scope "$scope"
  done < <(for scope in $scopes; do az role definition list --custom-role-only true --scope "$scope" -o json 2>/dev/null; done \
    | jq -rs --argjson p "$prefixes" 'add // [] | unique_by(.name)[]
        | select(all(.assignableScopes[] | ascii_downcase; . as $x | any($p[]; $x == . or ($x | startswith(. + "/")))))
        | [.id, .assignableScopes[0], .roleName] | @tsv')

  step ""
}

echo "Tenant: $TENANT, signed in as $(az account show --query user.name -o tsv) (your own role assignments stay)"
echo "Subscriptions:"
for sub in $SUBSCRIPTIONS; do echo "  ${SUB_NAME[$sub]:-?} ($sub)"; done

if [ "$DRY_RUN" = true ]; then
  log "=== DRY RUN - nothing is deleted"
  pass
  log "=== dry run: $found items would be deleted; run with --apply to delete them"
  exit 0
fi

echo
echo "This deletes EVERYTHING in tenant $TENANT and in the subscriptions listed above."
read -r -p "Type the tenant ID to continue: " answer
[ "$answer" = "$TENANT" ] || { echo "Aborted."; exit 1; }

for i in $(seq 1 "$PASSES"); do
  log "=== pass $i/$PASSES"
  found=0 failed=0
  pass
  log "=== pass $i: $found found, $failed failed"
  [ "$found" -eq 0 ] && { log "Tenant emptied."; exit 0; }
  [ "$i" -lt "$PASSES" ] && { log "pausing 60s before the next pass (deletions in Azure settle)"; sleep 60; }
done
echo "Something is still left after $PASSES passes (see above); run the script again." >&2
exit 1
