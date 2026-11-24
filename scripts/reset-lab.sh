#!/usr/bin/env bash
# Removes everything the platform and AKS stacks created in the build tenant lab, so it can be redeployed from
# scratch. Run by the "Lab reset" workflow (.github/workflows/lab-reset.yaml) with the platform apply identity.
#
# Kept: the subscriptions, the accelerator bootstrap and the public DNS zone (resource groups matching
# PROTECTED_RG_REGEX: Terraform state storage, the plan / apply identities and rg-onek8s-dns with onek8s.lol, which
# is created outside Terraform and delegated at the registrar, so its name servers must never change) and the `alz` management group the bootstrap created (the identities'
# role assignments live there; subscriptions under its children are moved up to it).
#
# Removed, in passes: resource locks, subscription budgets, policy assignments and exemptions, the role assignments the ALZ module
# creates for policy identities, resource groups, custom policy (set) definitions, the ALZ custom roles and custom
# roles scoped to the subscriptions, the management groups below `alz`, and – only once nothing is left – the
# Terraform state of the platform and AKS stacks. A failing deletion is logged and retried in the next pass.
#
# SKIP_POLICIES=true (the workflow's default) keeps everything Azure Policy is made of, because removing it takes
# most of the time: the management groups below `alz` with the subscriptions in them, policy assignments,
# exemptions and (set) definitions, the role assignments of policy identities, the ALZ custom roles, and the
# Terraform state that holds them – the platform's (terraform.tfstate) and AKS policy's (aks-*-policy.tfstate).
# Everything else goes as usual; the next Platform and AKS policy runs recreate what their state no longer finds.
#
# Environment: SUBSCRIPTIONS (space-separated), ROOT_MG (alz), STATE_ACCOUNT, STATE_CONTAINER, PROTECTED_RG_REGEX,
# DRY_RUN (true/false), SKIP_POLICIES (true/false), MAX_PASSES, PASS_PAUSE_SECONDS; on GitHub Actions also AZURE_CLIENT_ID, AZURE_TENANT_ID and
# AZURE_SUBSCRIPTION_ID, to sign in again with a fresh OIDC token (see relogin).
set -uo pipefail

ROOT_MG="${ROOT_MG:-alz}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_POLICIES="${SKIP_POLICIES:-false}"
MAX_PASSES="${MAX_PASSES:-5}"
PASS_PAUSE_SECONDS="${PASS_PAUSE_SECONDS:-60}"
PROTECTED_RG_REGEX="${PROTECTED_RG_REGEX:-^(rg-alz-build-|rg-onek8s-dns$)}"
STATE_BLOB_REGEX='^(terraform|platform-extensions|aks-.*)\.tfstate$'
KEPT_STATE_REGEX='^$' # nothing; with SKIP_POLICIES the state of the kept policies
if [ "$SKIP_POLICIES" = true ]; then KEPT_STATE_REGEX='^(terraform|aks-.*-policy)\.tfstate$'; fi
ALZ_ROLE_ASSIGNMENT_DESCRIPTION="Created by ALZ Terraform provider. Assignment required for Azure Policy."
MG_PREFIX="/providers/Microsoft.Management/managementGroups"

# azure/login's federated assertion expires after a few minutes, and a token for a new resource (Storage) or a
# refresh after an hour then fails – the listings below swallow errors, so a lapsed login would look like an empty
# lab. Sign in again with a fresh GitHub OIDC token before each pass and before the state is deleted.
relogin() {
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${AZURE_CLIENT_ID:-}" ] || return 0
  local token
  token="$(curl -sSf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
    && az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
         --federated-token "$token" --output none \
    && { [ -z "${AZURE_SUBSCRIPTION_ID:-}" ] || az account set --subscription "$AZURE_SUBSCRIPTION_ID"; } \
    || { echo "::error::Could not sign in to Azure again with a fresh OIDC token."; exit 1; }
}

failed=0
try() { # <description> <command...>: runs the command, logs and counts a failure, never exits
  local what="$1"; shift
  if [ "$DRY_RUN" = true ]; then echo "  would delete: $what"; return 0; fi
  local out
  if out="$("$@" 2>&1)"; then
    echo "  deleted: $what"
  else
    failed=$((failed + 1))
    echo "::warning::could not delete $what: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
}

# --- discovery -----------------------------------------------------------------------------------------------
# Management groups below ROOT_MG, deepest first, and the subscriptions placed in them
mg_tree() { az account management-group show --name "$ROOT_MG" --expand --recurse -o json 2>/dev/null || echo '{}'; }
child_mgs() {
  mg_tree | jq -r 'def walk_mg(d): (.children // [])[] | select(.type | test("managementGroups$"))
                     | ({name, depth: d}, walk_mg(d + 1));
                   [walk_mg(1)] | sort_by(-.depth) | .[].name'
}
subscriptions_in_child_mgs() {
  mg_tree | jq -r '(.children // [])[] | select(.type | test("managementGroups$"))
                   | .. | objects | select(.type == "/subscriptions") | .name'
}
mg_scopes() { echo "$MG_PREFIX/$ROOT_MG"; for mg in $(child_mgs); do echo "$MG_PREFIX/$mg"; done; }

policy_assignments() { # scope<TAB>name of assignments made directly at the MGs and subscriptions (not inherited)
  for scope in $(mg_scopes); do
    az policy assignment list --scope "$scope" --query "[?scope=='$scope'].[scope, name]" -o tsv 2>/dev/null
  done
  for sub in $SUBSCRIPTIONS; do # not Azure's own default Defender assignment
    az policy assignment list --subscription "$sub" \
      --query "[?scope=='/subscriptions/$sub' && name!='SecurityCenterBuiltIn'].[scope, name]" -o tsv 2>/dev/null
  done
}
policy_exemptions() {
  for scope in $(mg_scopes); do
    az policy exemption list --scope "$scope" --query "[].id" -o tsv 2>/dev/null
  done
  for sub in $SUBSCRIPTIONS; do
    az policy exemption list --subscription "$sub" --query "[].id" -o tsv 2>/dev/null
  done
}
alz_role_assignments() { # only the ones the ALZ module made for policy identities – never the bootstrap identities'
  local q="[?description=='$ALZ_ROLE_ASSIGNMENT_DESCRIPTION'].id"
  for scope in $(mg_scopes); do az role assignment list --scope "$scope" --query "$q" -o tsv 2>/dev/null; done
  for sub in $SUBSCRIPTIONS; do az role assignment list --all --subscription "$sub" --query "$q" -o tsv 2>/dev/null; done
}
resource_groups() { # subscription<TAB>name<TAB>managedBy, without the protected bootstrap groups
  local name managed_by
  for sub in $SUBSCRIPTIONS; do # the regex tests the name alone: anchors such as `rg-onek8s-dns$` must not see managedBy
    while IFS=$'\t' read -r name managed_by; do
      [ -z "$name" ] || [[ "$name" =~ $PROTECTED_RG_REGEX ]] && continue
      printf '%s\t%s\t%s\n' "$sub" "$name" "$managed_by"
    done < <(az group list --subscription "$sub" --query "[].[name, managedBy]" -o tsv 2>/dev/null)
  done
}
budgets() { # subscription budgets (aks-terraform shared/ budget.tf): subscription-scoped, so no resource group takes them
  for sub in $SUBSCRIPTIONS; do
    az rest --method get --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" \
      --query "value[].id" -o tsv 2>/dev/null
  done
}
locks() { # every lock in the subscriptions except those inside the protected resource groups
  local id rg
  for sub in $SUBSCRIPTIONS; do
    for id in $(az lock list --subscription "$sub" --query "[].id" -o tsv 2>/dev/null); do
      rg="$(sed -nE 's|^/subscriptions/[^/]+/resourceGroups/([^/]+)/.*|\1|ip' <<<"$id")"
      if [ -n "$rg" ] && grep -Eq "$PROTECTED_RG_REGEX" <<<"$rg"; then continue; fi
      echo "$id"
    done
  done
}
policy_set_definitions() { # kind<TAB>scope-arg<TAB>name of custom initiatives defined at the MGs / subscriptions
  for mg in "$ROOT_MG" $(child_mgs); do
    az policy set-definition list --management-group "$mg" \
      --query "[?policyType=='Custom' && starts_with(id, '$MG_PREFIX/$mg/')].name" -o tsv 2>/dev/null | sed "s|^|mg\t$mg\t|"
  done
  for sub in $SUBSCRIPTIONS; do
    az policy set-definition list --subscription "$sub" \
      --query "[?policyType=='Custom' && starts_with(id, '/subscriptions/$sub/')].name" -o tsv 2>/dev/null | sed "s|^|sub\t$sub\t|"
  done
}
policy_definitions() {
  for mg in "$ROOT_MG" $(child_mgs); do
    az policy definition list --management-group "$mg" \
      --query "[?policyType=='Custom' && starts_with(id, '$MG_PREFIX/$mg/')].name" -o tsv 2>/dev/null | sed "s|^|mg\t$mg\t|"
  done
  for sub in $SUBSCRIPTIONS; do
    az policy definition list --subscription "$sub" \
      --query "[?policyType=='Custom' && starts_with(id, '/subscriptions/$sub/')].name" -o tsv 2>/dev/null | sed "s|^|sub\t$sub\t|"
  done
}
custom_roles() { # id<TAB>name: the ALZ library roles "<name> (<mg>)" and roles whose scopes are all in the subscriptions
  local all mgs; mapfile -t all < <(echo "$ROOT_MG"; child_mgs)
  mgs="$(IFS='|'; echo "${all[*]}")"
  [ "$SKIP_POLICIES" = true ] || az role definition list --custom-role-only true --scope "$MG_PREFIX/$ROOT_MG" -o json 2>/dev/null \
    | jq -r --arg re " \\(($mgs)\\)$" '.[] | select(.roleName | test($re)) | [.id, .roleName] | @tsv'
  for sub in $SUBSCRIPTIONS; do
    az role definition list --custom-role-only true --subscription "$sub" -o json 2>/dev/null \
      | jq -r --arg sub "/subscriptions/$sub" '.[] | select(all(.assignableScopes[]; startswith($sub))) | [.id, .roleName] | @tsv'
  done | sort -u
}

left=0
report() { # prints what is left and sets $left; succeeds when nothing is left
  local lines
  left=0
  for kind in locks budgets resource_groups custom_roles \
              $( [ "$SKIP_POLICIES" = true ] || echo policy_assignments policy_exemptions alz_role_assignments \
                   policy_set_definitions policy_definitions child_mgs ); do
    lines="$($kind | sed '/^$/d')"
    if [ -n "$lines" ]; then
      echo "$kind:"; printf '%s\n' "$lines" | sed 's/^/  /'
      left=$((left + $(printf '%s\n' "$lines" | wc -l)))
    fi
  done
  [ "$left" -eq 0 ]
}

# --- one pass ------------------------------------------------------------------------------------------------
pass() {
  echo "::group::locks"
  for id in $(locks); do try "lock $id" az lock delete --ids "$id"; done
  echo "::endgroup::"

  echo "::group::budgets"
  for id in $(budgets); do try "budget $id" az rest --method delete --url "https://management.azure.com$id?api-version=2023-05-01"; done
  echo "::endgroup::"

  if [ "$SKIP_POLICIES" != true ]; then
  echo "::group::policy assignments and exemptions"
  while IFS=$'\t' read -r scope name; do
    [ -n "$name" ] && try "policy assignment $scope/$name" az policy assignment delete --scope "$scope" --name "$name"
  done < <(policy_assignments)
  for id in $(policy_exemptions); do try "policy exemption $id" az policy exemption delete --ids "$id"; done
  echo "::endgroup::"

  echo "::group::role assignments of policy identities"
  for id in $(alz_role_assignments); do try "role assignment $id" az role assignment delete --ids "$id"; done
  echo "::endgroup::"

  echo "::group::subscriptions back to $ROOT_MG"
  for sub in $(subscriptions_in_child_mgs); do
    try "placement of subscription $sub (moved to $ROOT_MG)" \
      az account management-group subscription add --name "$ROOT_MG" --subscription "$sub"
  done
  echo "::endgroup::"
  fi

  echo "::group::resource groups"
  local deleting=()
  while IFS=$'\t' read -r sub rg managed_by; do
    [ -z "$rg" ] && continue
    if [ -n "$managed_by" ] && [ "$managed_by" != "None" ]; then
      echo "  skipped: $sub/$rg (managed by $managed_by, goes with its owner)"; continue
    fi
    try "resource group $sub/$rg" az group delete --subscription "$sub" --name "$rg" --yes --no-wait \
      && deleting+=("$sub/$rg")
  done < <(resource_groups)
  if [ "$DRY_RUN" != true ]; then
    for item in "${deleting[@]}"; do
      az group wait --subscription "${item%%/*}" --name "${item#*/}" --deleted --timeout 1800 >/dev/null 2>&1 \
        || echo "::warning::resource group $item is still being deleted, retried in the next pass"
    done
  fi
  echo "::endgroup::"

  if [ "$SKIP_POLICIES" != true ]; then
  echo "::group::custom policy set definitions and definitions"
  while IFS=$'\t' read -r kind where name; do
    [ -z "$name" ] && continue
    if [ "$kind" = mg ]; then try "policy set definition $where/$name" az policy set-definition delete --management-group "$where" --name "$name"
    else try "policy set definition $where/$name" az policy set-definition delete --subscription "$where" --name "$name"; fi
  done < <(policy_set_definitions)
  while IFS=$'\t' read -r kind where name; do
    [ -z "$name" ] && continue
    if [ "$kind" = mg ]; then try "policy definition $where/$name" az policy definition delete --management-group "$where" --name "$name"
    else try "policy definition $where/$name" az policy definition delete --subscription "$where" --name "$name"; fi
  done < <(policy_definitions)
  echo "::endgroup::"
  fi

  echo "::group::custom roles"
  local scope
  while IFS=$'\t' read -r id name; do
    [ -z "$id" ] && continue
    scope="${id%%/providers/Microsoft.Authorization/*}" # empty for roles defined at a management group
    try "custom role '$name'" az role definition delete --name "${id##*/}" --scope "${scope:-$MG_PREFIX/$ROOT_MG}"
  done < <(custom_roles)
  echo "::endgroup::"

  if [ "$SKIP_POLICIES" != true ]; then
  echo "::group::management groups below $ROOT_MG"
  for mg in $(child_mgs); do try "management group $mg" az account management-group delete --name "$mg"; done
  echo "::endgroup::"
  fi
}

delete_state() {
  local all blobs
  if ! all="$(az storage blob list --account-name "$STATE_ACCOUNT" --container-name "$STATE_CONTAINER" --auth-mode login \
    --query "[].name" -o tsv)"; then
    failed=$((failed + 1)); echo "::error::Could not list the state blobs in $STATE_CONTAINER."; return 1
  fi
  blobs="$(grep -E "$STATE_BLOB_REGEX" <<<"$all" | grep -Ev "$KEPT_STATE_REGEX")"
  [ -z "$blobs" ] && echo "  no state blobs matching $STATE_BLOB_REGEX"
  for blob in $blobs; do
    az storage blob lease break --account-name "$STATE_ACCOUNT" --container-name "$STATE_CONTAINER" --blob-name "$blob" \
      --auth-mode login >/dev/null 2>&1 || true # stale lock of a cancelled run
    try "state $STATE_CONTAINER/$blob" az storage blob delete --account-name "$STATE_ACCOUNT" \
      --container-name "$STATE_CONTAINER" --name "$blob" --delete-snapshots include --auth-mode login
  done
}

# --- main ----------------------------------------------------------------------------------------------------
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1
echo "Subscriptions: $SUBSCRIPTIONS"
echo "Kept: management group $ROOT_MG, resource groups matching $PROTECTED_RG_REGEX"
[ "$SKIP_POLICIES" = true ] && echo "Kept (SKIP_POLICIES): management groups, Azure Policy, ALZ custom roles, state blobs matching $KEPT_STATE_REGEX"

if [ "$DRY_RUN" = true ]; then
  echo "Dry run – would delete:"; report
  echo "Terraform state blobs matching $STATE_BLOB_REGEX but not $KEPT_STATE_REGEX in $STATE_CONTAINER"
  exit 0
fi

clean=false
for i in $(seq 1 "$MAX_PASSES"); do
  echo "=== pass $i/$MAX_PASSES"
  relogin
  pass
  relogin
  echo "=== left after pass $i ($failed failed deletions so far):"
  if report; then echo "nothing left"; clean=true; break; fi
  echo "$left items left"
  [ "$i" -lt "$MAX_PASSES" ] && sleep "$PASS_PAUSE_SECONDS"
done

# The last report already checked everything; scanning again only adds minutes of silence before the state step
if [ "$clean" = true ]; then
  echo "=== Terraform state ($STATE_CONTAINER in $STATE_ACCOUNT)"
  failed=0
  relogin
  delete_state
  [ "$failed" -eq 0 ] && { echo "Lab reset complete."; exit 0; }
  echo "::error::Could not delete every Terraform state blob."; exit 1
fi
echo "::error::Resources are left after $MAX_PASSES passes (listed above); the Terraform state was kept. Run the workflow again."
exit 1
