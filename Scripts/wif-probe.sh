#!/usr/bin/env bash
# Workload Identity Federation probe — can shotAI trade an Entra sign-in for a
# short-lived Anthropic token, with no API key on the user's machine? (#62 / SSO)
#
# WIF is documented only for MACHINE workloads (Azure managed identities via
# IMDS, AKS workload identity, GitHub Actions OIDC). A laptop has none of those.
# The undocumented question was whether a *human's* Entra token is accepted as the
# RFC 7523 assertion.
#
# ANSWERED 2026-08-18: YES. A delegated Entra v2.0 token (scp=user_impersonation)
# was accepted and exchanged for an sk-ant-oat01- token that called the Messages
# API. So this script is no longer a go/no-go on the design — it is a CONFIGURATION
# checker. A failure now means the tenant or the federation rule is set up wrong,
# NOT that the approach doesn't work. Read the verdict text with that in mind.
#
#   bash Scripts/wif-probe.sh
#
# Run it twice: pass 1 provisions Entra and prints the values for the Claude
# Console; pass 2 (after you create the federation rule) runs the exchange.
#
# THE FAILURE MODE THIS SCRIPT GUARDS HARDEST AGAINST is a false PASS. An
# app-only token (from `az login --service-principal`) carries iss/aud/tid
# byte-identical to a user token, so it would sail through every obvious check
# and "prove" a design that has not been tested. Step 4 refuses to proceed
# unless the assertion is demonstrably user-derived.
#
# Creates in YOUR Entra tenant (announced, with a confirmation prompt): one app
# registration + service principal named `claude-api-federation`. Creates nothing
# in the Anthropic org — the Console wizard does that. Credentials are never
# printed in full and never appear on a command line.
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shotai"
CONFIG="$CONFIG_DIR/wif-probe.env"
APP_NAME="claude-api-federation"
AZ_CLI_APP_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Microsoft Azure CLI, first-party

# Two separate buckets, deliberately. BLOCKERS decide the verdict; WARNINGS are
# setup friction that must never turn a working federation into "[FAIL]".
BLOCKERS=()
WARNINGS=()
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/wifprobe.XXXXXX")" || exit 1
chmod 700 "$TMPDIR_RUN"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT INT TERM

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
blocker(){ printf '  \033[31m✗\033[0m %s\n' "$1"; BLOCKERS+=("$1"); }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; WARNINGS+=("$1"); }
info()  { printf '    %s\n' "$*"; }
step()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()   { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 2; }

# Show that a credential exists without disclosing it.
peek() { local v="${1:-}"; [ -n "$v" ] || { printf '(empty)'; return; }; printf '%s… (%d chars)' "${v:0:10}" "${#v}"; }

# Shell-quote a value so the cache can never execute anything when sourced.
save() { # save KEY VALUE
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  touch "$CONFIG"; chmod 600 "$CONFIG"
  local tmp="$TMPDIR_RUN/cfg"
  grep -v "^$1=" "$CONFIG" 2>/dev/null > "$tmp" || true
  printf '%s=%q\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$CONFIG"
}

ask() { # ask KEY "Prompt" REGEX  → value on stdout
  local key="$1" prompt="$2" re="$3" cur="${!1:-}" val
  if [ -n "$cur" ]; then
    printf '    %-34s %s \033[2m(cached)\033[0m\n' "$prompt:" "$cur" >&2
    printf '%s' "$cur"; return
  fi
  while :; do
    if ! read -r -p "    $prompt: " val < /dev/tty; then
      die "no terminal available for input — run this script interactively (not via 'ssh host cmd', cron, or an IDE task pane)"
    fi
    [[ "$val" =~ $re ]] && break
    printf '    not in the expected form, try again\n' >&2
  done
  save "$key" "$val"; printf '%s' "$val"
}

pause() { # pause "text"
  read -r -p "    $1" _ < /dev/tty || die "no terminal available for input — run this script interactively"
}

claim() { # claim <jwt> <name>  → value ("" if absent); lists join on ","
  python3 - "$1" "$2" <<'PY'
import base64, json, sys
try:
    p = sys.argv[1].split(".")[1]
    c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    v = c.get(sys.argv[2], "")
    print(",".join(map(str, v)) if isinstance(v, list) else v, end="")
except Exception:
    print("", end="")
PY
}

FRESH=0
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      printf '\nOptions:\n'
      printf '  --fresh   Re-authenticate before requesting the token. Use this after\n'
      printf '            changing an App Role assignment, and before any repeat run.\n'
      printf '  -h        This help.\n\n'
      printf 'Any cached value can be overridden for one run from the environment, e.g.\n'
      printf '  FDRL=fdrl_… bash %s --fresh\n' "$0"
      printf 'which is how you dry-run a parallel federation rule without touching the\n'
      printf 'live one.\n'
      exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$a" >&2; exit 2 ;;
  esac
done

bold "shotAI — Entra → Anthropic federation probe"

# Environment beats the cache file. `. "$CONFIG"` would otherwise silently
# overwrite an explicit `FDRL=fdrl_test bash Scripts/wif-probe.sh` — which is
# exactly the invocation for dry-running a PARALLEL federation rule. Anthropic
# selects rules by ID with no implicit search, so a second rule is invisible to
# production and is the only zero-risk way to test a match change (#69).
# Fixed name list, so the eval cannot be an injection vector.
CFG_KEYS="FDRL SVAC ORG_ID WRKSPC TENANT_ID APP_ID"
for v in $CFG_KEYS; do [ -n "${!v:-}" ] && eval "__env_$v=\${$v}"; done
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
# ask() only regex-checks values it PROMPTS for, so an env-supplied one would
# skip validation. Validate here instead: a fat-fingered rule ID produces the
# same opaque 401 as a genuine mismatch, and you would debug the rule.
env_re() {
  case "$1" in
    FDRL)      printf '^fdrl_[A-Za-z0-9_-]+$' ;;
    SVAC)      printf '^svac_[A-Za-z0-9_-]+$' ;;
    WRKSPC)    printf '^(wrkspc_[A-Za-z0-9_-]+|default)$' ;;
    ORG_ID)    printf '^[0-9a-fA-F-]{36}$' ;;
    TENANT_ID|APP_ID) printf '^[0-9a-fA-F-]{36}$' ;;
    *)         printf '.' ;;
  esac
}
for v in $CFG_KEYS; do
  e="__env_$v"
  if [ -n "${!e:-}" ]; then
    eval "$v=\${$e}"
    [[ "${!v}" =~ $(env_re "$v") ]] || die "$v was set in the environment to '${!v}',
    which is not a valid $v. Fix the value rather than letting it reach the
    exchange — a bad ID fails with the same opaque 401 as a real mismatch."
    printf '    %-34s %s \033[2m(from environment, not cached)\033[0m\n' "$v" "${!v}"
  fi
done

# ── 0. Prerequisites ─────────────────────────────────────────────────────────
step "Checking prerequisites"
for c in az python3 curl; do
  command -v "$c" >/dev/null || die "$c not found. Install the Azure CLI with: brew install azure-cli"
done
ok "az, python3, curl present"

# Prove a terminal exists BEFORE touching Entra. ask() runs inside a command
# substitution, so a die() in there would only kill the subshell and leave the
# parent running with an empty value — check once, here, where die() works.
{ exec 3< /dev/tty; } 2>/dev/null || die "no terminal available for input.

    This script asks four questions partway through, so it has to be run
    interactively — not via 'ssh host command' (use 'ssh -t'), cron, launchd,
    or an IDE task pane."
exec 3<&-
ok "interactive terminal available"

az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"

# THE load-bearing check. An app-only token proves nothing about the design and
# is indistinguishable from a user token by iss/aud/tid alone.
ACCT_TYPE="$(az account show --query user.type -o tsv 2>/dev/null)"
ACCT_NAME="$(az account show --query user.name -o tsv 2>/dev/null)"
if [ "$ACCT_TYPE" != "user" ]; then
  die "signed in to Azure as '${ACCT_TYPE:-unknown}' ($ACCT_NAME), not a user.

    This probe only has meaning for a HUMAN sign-in — that is the whole
    question. A service-principal login would mint an app-only token whose
    iss/aud/tid are identical to a user's, so the exchange could succeed and
    tell you nothing about whether shotAI's real sign-in flow will work.

    Run:  az logout && az login"
fi
ok "signed in as a user: $ACCT_NAME"

TENANT_ID="$(az account show --query tenantId -o tsv)"
ok "tenant $TENANT_ID"
save TENANT_ID "$TENANT_ID"

# ── 1. Consent before touching the directory ─────────────────────────────────
step "About to modify your Entra tenant"
cat <<EOF

    This creates (or reuses) in tenant $TENANT_ID:
      · an app registration named "$APP_NAME"
      · its service principal
      · a delegated scope "user_impersonation" on it, user-consentable
      · a pre-authorization letting the Azure CLI request tokens for it

    It creates nothing in the Anthropic organization and deletes nothing.
    To remove it afterwards:  az ad app delete --id <APP_ID>

EOF
pause "Type Return to continue, Ctrl-C to stop: "

# ── 2. Audience app registration ─────────────────────────────────────────────
# Entra refuses to mint a token for an audience that does not exist in the
# tenant as an app registration WITH a service principal (AADSTS500011).
step "Entra app registration ($APP_NAME)"
MATCHES="$(az ad app list --display-name "$APP_NAME" --query 'length(@)' -o tsv 2>/dev/null || echo 0)"
APP_ID="${APP_ID:-}"
if [ -n "$APP_ID" ]; then
  az ad app show --id "$APP_ID" >/dev/null 2>&1 \
    && ok "reusing $APP_ID from the cache" \
    || { warn "cached APP_ID $APP_ID no longer exists — creating a new registration"; APP_ID=""; }
fi
if [ -z "$APP_ID" ]; then
  if [ "${MATCHES:-0}" -gt 1 ] 2>/dev/null; then
    warn "$MATCHES registrations are named '$APP_NAME'; using the first. Delete the duplicates if this is not the one you want."
  fi
  if [ "${MATCHES:-0}" -ge 1 ] 2>/dev/null; then
    APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
    ok "reusing existing registration"
  else
    APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)" \
      || die "could not create the app registration (you need permission to register applications in Entra)"
    ok "created"
  fi
fi
info "Application (client) ID: $APP_ID"
save APP_ID "$APP_ID"

# Directory writes are eventually consistent; a show() straight after create()
# can 404 for a few seconds.
APP_OBJ=""
for _ in 1 2 3 4 5 6; do
  APP_OBJ="$(az ad app show --id "$APP_ID" --query id -o tsv 2>/dev/null)"
  [ -n "$APP_OBJ" ] && break
  sleep 3
done
[ -n "$APP_OBJ" ] || die "the registration was created but is not readable yet — wait a minute and re-run"

if az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  ok "service principal exists"
else
  if az ad sp create --id "$APP_ID" >"$TMPDIR_RUN/sp.log" 2>&1; then
    ok "service principal created"
  else
    warn "could not create the service principal — the token request will fail with AADSTS500011"
    info "$(head -2 "$TMPDIR_RUN/sp.log")"
  fi
fi

# ── 3. Expose the API and pre-authorize the Azure CLI ────────────────────────
#   requestedAccessTokenVersion=2 → v2.0 tokens (iss ends /v2.0, aud is the bare
#     appId GUID), which is what the federation rule below matches.
#   preAuthorizedApplications → the CLI can request this audience with no consent prompt.
step "Configuring the API surface"

# Is it ALREADY configured? Every write below is idempotent in intent but not in
# privilege: re-running them needs Application.ReadWrite.All, which a normal
# account (or an admin whose PIM activation has lapsed) does not have. Without
# this check a perfectly working setup reports four red lines and dies, because
# blockers were recorded before the verification that says everything is fine.
# Read all four properties in ONE call and skip the whole block if they hold.
CFG_Q='{u:identifierUris,v:api.requestedAccessTokenVersion'
CFG_Q="$CFG_Q"',s:api.oauth2PermissionScopes[?value==`user_impersonation`].id|[0]'
CFG_Q="$CFG_Q"',p:api.preAuthorizedApplications[?appId==`'"$AZ_CLI_APP_ID"'`].appId|[0]}'
ALREADY="$(az ad app show --id "$APP_ID" --query "$CFG_Q" -o json 2>/dev/null \
  | python3 -c '
import json, sys
try:    d = json.load(sys.stdin)
except Exception: print("no"); raise SystemExit
want = "api://" + sys.argv[1]
ok = (want in (d.get("u") or [])
      and d.get("v") == 2
      and d.get("s")
      and d.get("p"))
print("yes" if ok else "no")
' "$APP_ID" 2>/dev/null)"

if [ "$ALREADY" = "yes" ]; then
  ok "already configured (identifier URI, v2.0 tokens, scope, CLI pre-auth)"
  info "Skipping the directory writes — nothing to change, so no Entra write"
  info "privileges are needed for this run."
else

SCOPE_ID="$(az ad app show --id "$APP_ID" --query 'api.oauth2PermissionScopes[0].id' -o tsv 2>/dev/null)"
[ -n "$SCOPE_ID" ] && [ "$SCOPE_ID" != "null" ] || SCOPE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

# Graph rejects a new oauth2PermissionScope and a preAuthorizedApplications
# reference to it in the SAME PATCH ("Permission Id that cannot be found in the
# AppPermissions sets"). The scope has to exist first, so this is two calls.
cat > "$TMPDIR_RUN/p1.json" <<JSON
{"api":{"requestedAccessTokenVersion":2,"oauth2PermissionScopes":[{
  "id":"$SCOPE_ID","value":"user_impersonation","type":"User","isEnabled":true,
  "adminConsentDisplayName":"Access the Claude API federation audience",
  "adminConsentDescription":"Allows requesting Entra tokens scoped to the Claude API federation audience.",
  "userConsentDisplayName":"Access the Claude API federation audience",
  "userConsentDescription":"Allows requesting Entra tokens scoped to the Claude API federation audience."}]}}
JSON
cat > "$TMPDIR_RUN/p2.json" <<JSON
{"api":{"preAuthorizedApplications":[{"appId":"$AZ_CLI_APP_ID","delegatedPermissionIds":["$SCOPE_ID"]}]}}
JSON

# The identifier URI is what makes api://<APP_ID> resolvable. Without it every
# token request dies with AADSTS500011, so this one is fatal, not advisory.
if az ad app update --id "$APP_ID" --identifier-uris "api://$APP_ID" 2>"$TMPDIR_RUN/uri.log"; then
  ok "identifier URI api://$APP_ID"
else
  blocker "could not set the identifier URI — api://$APP_ID will not resolve"
  info "$(head -3 "$TMPDIR_RUN/uri.log")"
fi

if az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJ" \
     --headers "Content-Type=application/json" --body "@$TMPDIR_RUN/p1.json" >/dev/null 2>"$TMPDIR_RUN/p1.log"; then
  ok "v2.0 tokens + user_impersonation scope"
else
  blocker "Graph PATCH (token version + scope) failed"
  info "$(head -3 "$TMPDIR_RUN/p1.log")"
  info "Most common cause: your account lacks Application.ReadWrite.All in Entra."
fi

if az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJ" \
     --headers "Content-Type=application/json" --body "@$TMPDIR_RUN/p2.json" >/dev/null 2>"$TMPDIR_RUN/p2.log"; then
  ok "Azure CLI pre-authorized"
else
  warn "could not pre-authorize the Azure CLI — expect a consent prompt on the token request"
  info "$(head -3 "$TMPDIR_RUN/p2.log")"
fi

fi   # end: skip-if-already-configured

# Read the state back rather than trusting the writes. Runs in BOTH branches —
# this, not the writes, is what decides whether the app is usable.
VERIFY="$(az ad app show --id "$APP_ID" --query '{u:identifierUris[0],v:api.requestedAccessTokenVersion}' -o tsv 2>/dev/null)"
case "$VERIFY" in
  "api://$APP_ID"*2*) ok "verified: identifier URI set, v2.0 tokens" ;;
  *) blocker "the app is not configured as required (identifierUris/tokenVersion: ${VERIFY:-unreadable})"
     info "Without both, the token request fails with AADSTS500011 or mints a v1 token"
     info "whose iss and aud will not match the federation rule." ;;
esac

if [ ${#BLOCKERS[@]} -ne 0 ]; then
  printf '\n\033[31m✗ Entra is not configured correctly — fix the above before continuing.\033[0m\n' >&2
  cat >&2 <<EOF

    If the verification line above says the identifier URI and v2.0 tokens are
    set, the app is FINE and these errors are re-provisioning attempts that your
    current sign-in lacks the rights for. Sign in as an account holding
    Application.ReadWrite.All (or re-activate the PIM role) and re-run, or
    ignore them if nothing about the app needs to change.

    DO NOT delete the app registration to "start clean" if a federation rule
    already matches it as the audience — that revokes every user at once.
EOF
  exit 1
fi

# ── 4. Values for the Claude Console ─────────────────────────────────────────
step "Create the federation rule in the Claude Console"
cat <<EOF

    Settings → Workload identity → Connect workload → Custom OIDC
    (NOT the Entra tile — that one is for managed identities, which a Mac has no
     equivalent of. Its "Object (principal) ID" field has nothing to fill it.)

      Issuer URL     https://login.microsoftonline.com/$TENANT_ID/v2.0
      JWKS           discovery
      Scope             workspace:inference
      Token lifetime    3600
      Max JWT lifetime  7200   <- raise it; the default 3600 is BELOW the
                                  ~3959s lifetime Entra actually issues

      Match
        audience     $APP_ID
        claims       tid = $TENANT_ID

    A rule whose only matcher is 'audience' is rejected at creation, so the tid
    claim is required. Once this probe passes, tighten it with a CEL condition
    on an app role.

EOF
pause "Press Return once the rule exists (Ctrl-C to stop here): "

FDRL="$(ask FDRL   'Federation rule ID (fdrl_…)' '^fdrl_[A-Za-z0-9_-]+$')"
SVAC="$(ask SVAC   'Service account ID (svac_…)' '^svac_[A-Za-z0-9_-]+$')"
ORG_ID="$(ask ORG_ID 'Anthropic org ID (uuid)'   '^[0-9a-fA-F-]{36}$')"
WRKSPC="$(ask WRKSPC 'Workspace ID (wrkspc_… or default)' '^(wrkspc_[A-Za-z0-9_-]+|default)$')"
# ask() runs in a subshell, so its die() cannot stop the parent. Re-check here.
for v in FDRL SVAC ORG_ID WRKSPC; do
  [ -n "${!v}" ] || die "$v was not captured — cannot continue"
done
info "(cached in $CONFIG — delete that file to re-enter them)"

# ── 5. Get a USER token from Entra ───────────────────────────────────────────
# `az account get-access-token` serves from the MSAL cache and has NO
# --force-refresh (Azure/azure-cli#17578, open since 2021). Two consecutive
# calls return byte-identical tokens. Two consequences, both of which look
# exactly like "the federation rule is wrong":
#   1. A newly-assigned App Role will not appear in a cached token, no matter
#      how long you wait or how many times you re-run this script.
#   2. Where the IdP emits a real `jti`, replaying a cached token replays it and
#      is rejected as single-use. NB Entra emits `uti`, not `jti`, and check_jti
#      is documented fail-open for tokens lacking one — so on this issuer that
#      second reason does not apply, and one token can be reused deliberately to
#      A/B two rule IDs with the match block as the only variable.
# A bare `az login` does NOT fix either: it mints an ARM-scoped token under a
# different cache key and leaves this resource's token untouched. Scoping the
# login to the resource is what actually refreshes it.
if [ "$FRESH" = "1" ]; then
  step "Re-authenticating for a genuinely fresh token (--fresh)"
  if az login --scope "api://$APP_ID/.default" >/dev/null 2>&1; then
    ok "re-authenticated against api://$APP_ID"
  else
    warn "az login --scope failed; falling back to whatever is cached"
    info "If roles/jti problems persist:  az account clear && az login"
  fi
fi

step "Requesting an Entra token for the signed-in user"
if ! JWT="$(az account get-access-token --resource "api://$APP_ID" --query accessToken -o tsv 2>"$TMPDIR_RUN/az.err")" \
   || [ -z "${JWT:-}" ]; then
  ERR="$(cat "$TMPDIR_RUN/az.err")"
  printf '  \033[31m✗\033[0m Entra would not issue a token\n'
  info "$(printf '%s' "$ERR" | head -4)"
  case "$ERR" in
    *AADSTS500011*|*AADSTS50001*)
      info "api://$APP_ID does not resolve in this tenant. Almost always the"
      info "identifier URI or the service principal is missing, NOT propagation."
      info "Check:  az ad app show --id $APP_ID --query identifierUris"
      info "        az ad sp show  --id $APP_ID --query id" ;;
    *AADSTS65001*)                info "Consent required. Re-run; if it persists, grant admin consent to $APP_NAME in Entra." ;;
    *AADSTS50076*|*AADSTS50079*)  info "Conditional Access wants MFA for this resource. Re-run 'az login' and complete it." ;;
    *)                            info "Entra app changes are eventually consistent — wait a minute and re-run." ;;
  esac
  die "cannot answer the question without an Entra token"
fi
ok "token issued: $(peek "$JWT")"

T_ISS="$(claim "$JWT" iss)";   T_AUD="$(claim "$JWT" aud)"
T_TID="$(claim "$JWT" tid)";   T_OID="$(claim "$JWT" oid)"
T_VER="$(claim "$JWT" ver)";   T_IDTYP="$(claim "$JWT" idtyp)"
T_SCP="$(claim "$JWT" scp)";   T_UPN="$(claim "$JWT" preferred_username)"
[ -n "$T_UPN" ] || T_UPN="$(claim "$JWT" upn)"
# App roles, once an App Role gates access (#69). claim() flattens arrays, so a
# single assignment prints as `shotAI.User`. Reported whether present or not:
# the point of this line is to let you confirm the role reaches the TOKEN before
# you make a federation rule depend on it. Doing it the other way round means
# saving a rule that matches nobody.
T_ROLES="$(claim "$JWT" roles)"

info "iss    $T_ISS"
info "aud    $T_AUD"
info "tid    $T_TID"
info "oid    $T_OID  (the user's stable object ID in this tenant)"
info "ver    ${T_VER:-(absent)}"
info "idtyp  ${T_IDTYP:-(absent — normal for a user token)}"
info "scp    ${T_SCP:-(absent)}"
info "upn    ${T_UPN:-(absent)}"
info "roles  ${T_ROLES:-(absent — no App Role assigned, or the token predates the assignment)}"

# Two issuer-level settings that silently reject an otherwise-valid assertion.
T_JTI="$(claim "$JWT" jti)"
SPREAD="$(python3 -c '
import base64, json, sys
try:
    p = sys.argv[1].split(".")[1]
    c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    print(int(c["exp"]) - int(c["iat"]), end="")
except Exception:
    print("", end="")
' "$JWT")"
info "jti           ${T_JTI:+present }${T_JTI:-(absent)}"
info "iat->exp span ${SPREAD:-?}s"

# Recorded, NOT warned. The 2026-08-18 PASS exchanged a 3959s token, so a span
# over the 3600 default is not on its own a failure -- and "or the exchange 400s"
# was simply false. Surfacing this as a warning cost an hour of chasing the wrong
# setting while the real cause (audience, then subject pattern) sat in History.
# It is only worth raising if the exchange actually fails AND History says so.
LONG_SPAN=0
if [ -n "$SPREAD" ] && [ "$SPREAD" -gt 3600 ] 2>/dev/null; then LONG_SPAN=1; fi
# Entra access tokens carry `uti`, not `jti`, and Anthropic's check_jti is
# documented fail-open ("tokens without one are accepted without single-use
# enforcement"), so this branch should not fire on an Entra issuer. It stays for
# the case where an optional claim or a different IdP puts a real jti in play.
if [ -n "$T_JTI" ]; then
  warn "token carries a jti and issuers default to check_jti=true (single-use)"
  info "az caches tokens, so a SECOND run may replay this jti and be rejected —"
  info "indistinguishable from a rule mismatch. Re-run with --fresh."
  info "Do NOT turn the issuer's check_jti off to get past this: check_jti is an"
  info "ISSUER-level setting shared by every rule on that issuer, so disabling it"
  info "removes replay protection from your production rule too."
fi

# Second gate on the token itself. `az account show` said "user"; this confirms
# the token Entra actually minted is delegated rather than app-only.
step "Confirming this is a user (delegated) token, not app-only"
if [ "$T_IDTYP" = "app" ]; then
  die "Entra minted an APP-ONLY token (idtyp=app). This proves nothing about the
    user sign-in path. Re-run 'az logout && az login' as a human."
fi
if [ -z "$T_SCP" ] && [ -z "$T_UPN" ]; then
  die "the token carries neither 'scp' nor a username claim, so it is not
    demonstrably user-derived. Refusing to report a result that could be a
    false PASS. Re-run 'az logout && az login' as a human."
fi
ok "delegated token${T_SCP:+ (scp: $T_SCP)}${T_UPN:+ · $T_UPN}"

# ── 6. Pre-flight ────────────────────────────────────────────────────────────
# The exchange returns a deliberately opaque 400. Catch the predictable
# mismatches here, where the message can be specific. These compare against the
# rule as INSTRUCTED above; if you configured it differently, ignore them.
# WHAT THIS CANNOT SEE: the rule's subject pattern, its additional claim
# conditions, and its CEL expression all live server-side. Those caused BOTH
# real-world failures (jwt_audience_mismatch, then match_subject_prefix) while
# this pre-flight reported all clear. A green pre-flight is weak evidence.
step "Pre-flight (iss/aud/tid only -- cannot see the rule's match config)"
PREFLIGHT_OK=1
EXPECT_ISS="https://login.microsoftonline.com/$TENANT_ID/v2.0"
if [ "$T_ISS" = "$EXPECT_ISS" ]; then ok "iss matches the issuer URL"; else
  PREFLIGHT_OK=0; blocker "iss mismatch"
  info "token: $T_ISS"; info "rule:  $EXPECT_ISS"
  info "Set the Console's issuer selector to v2.0 — it defaults to v1."
fi
if [ "$T_AUD" = "$APP_ID" ]; then ok "aud matches the rule's audience"; else
  PREFLIGHT_OK=0; blocker "aud mismatch"
  info "token: $T_AUD"; info "rule:  $APP_ID"
fi
if [ "$T_TID" = "$TENANT_ID" ]; then ok "tid matches"; else
  PREFLIGHT_OK=0; blocker "tid mismatch: token $T_TID vs rule $TENANT_ID"
fi

# ── 7. The exchange — this is the answer ─────────────────────────────────────
step "Exchanging the user token for an Anthropic token"
python3 - "$JWT" "$FDRL" "$ORG_ID" "$SVAC" "$WRKSPC" > "$TMPDIR_RUN/body.json" <<'PY'
import json, sys
_, jwt, fdrl, org, svac, ws = sys.argv
print(json.dumps({
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion": jwt, "federation_rule_id": fdrl,
    "organization_id": org, "service_account_id": svac,
    "workspace_id": ws,   # "default" is a legal literal, not a sentinel
}))
PY
chmod 600 "$TMPDIR_RUN/body.json"

# Body via file, not argv — the assertion must not be visible in `ps`.
HTTP="$(curl -sS -o "$TMPDIR_RUN/exch.json" -w '%{http_code}' \
  --max-time 30 https://api.anthropic.com/v1/oauth/token \
  -H 'content-type: application/json' \
  --data-binary "@$TMPDIR_RUN/body.json" 2>"$TMPDIR_RUN/curl.err")"

if [ "$HTTP" = "000" ] || [ -z "$HTTP" ]; then
  blocker "could not reach api.anthropic.com (network/TLS, not a federation answer)"
  info "$(head -2 "$TMPDIR_RUN/curl.err")"
elif [ "$HTTP" != "200" ]; then
  blocker "exchange returned HTTP $HTTP"
  python3 -m json.tool < "$TMPDIR_RUN/exch.json" 2>/dev/null | sed 's/^/    /' || sed 's/^/    /' "$TMPDIR_RUN/exch.json"
  cat <<EOF

    Every exchange failure returns the same opaque 400; the real cause is logged
    server-side only. Go to:

      Claude Console → Settings → Workload identity → History

    It names the issuer and rule evaluated, the claims inspected, and the check
    that failed. That page answers this in seconds; guessing does not.

EOF
  if [ "$PREFLIGHT_OK" = "1" ]; then
    cat <<'EOF'
    Pre-flight passed, which means less than it sounds like. It compares only
    iss, aud and tid. It cannot see the rule's subject pattern, additional claim
    conditions, or CEL expression -- and those were the cause of every real
    failure so far, each time while pre-flight reported all clear.

    Do NOT read a green pre-flight as "the token is fine, so the design must be
    wrong." The design is proven (2026-08-18). This is a config error. History
    names it; guessing from out here produced two wrong hypotheses in a row.

EOF
  fi
  if [ "$LONG_SPAN" = "1" ]; then
    cat <<EOF
    Only if History names a lifetime/expiry reason: this token's iat->exp span
    is ${SPREAD}s against an issuer default of 3600, so raise the issuer's Max
    JWT lifetime to 7200. A long span alone is NOT a failure -- a 3959s token
    has exchanged successfully. Do not change this on spec.

EOF
  fi
else
  ACCESS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("access_token",""),end="")' "$TMPDIR_RUN/exch.json")"
  EXPIRES="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("expires_in",""),end="")' "$TMPDIR_RUN/exch.json")"
  SCOPE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("scope",""),end="")' "$TMPDIR_RUN/exch.json")"
  ok "exchange succeeded — a user assertion was ACCEPTED"
  info "access_token $(peek "$ACCESS")"
  info "expires_in   ${EXPIRES}s"
  info "scope        $SCOPE"
  case "$ACCESS" in
    sk-ant-oat01-*) ok "short-lived OAuth token, not a static key" ;;
    *)              warn "token does not carry the expected sk-ant-oat01- prefix" ;;
  esac

  # ── 8. End-to-end. Informational: federation is already proven above. ──────
  step "Calling the Messages API with it"
  printf 'header = "authorization: Bearer %s"\n' "$ACCESS" > "$TMPDIR_RUN/curlrc"
  chmod 600 "$TMPDIR_RUN/curlrc"
  MHTTP="$(curl -sS -o "$TMPDIR_RUN/msg.json" -w '%{http_code}' \
    --max-time 60 --config "$TMPDIR_RUN/curlrc" https://api.anthropic.com/v1/messages \
    -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    -d '{"model":"claude-opus-5","max_tokens":16,"messages":[{"role":"user","content":"Reply with the single word: federated"}]}' \
    2>"$TMPDIR_RUN/curl2.err")"
  case "$MHTTP" in
    200) ok "Claude replied: $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next((b["text"] for b in d["content"] if b["type"]=="text"),"(no text)"),end="")' "$TMPDIR_RUN/msg.json" 2>/dev/null)" ;;
    403) warn "403 — token valid, but its scope excludes Messages. Set the rule's scope to workspace:inference." ;;
    000|"") warn "could not reach the Messages endpoint (network). Federation itself is already proven." ;;
    *)   warn "Messages returned HTTP $MHTTP — unrelated to federation (model access, credit, or rate limit)"
         info "$(head -3 "$TMPDIR_RUN/msg.json")" ;;
  esac
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
# Gated ONLY on blockers. Setup friction and post-exchange hiccups are warnings:
# a working federation must never be reported as a failure.
echo
if [ ${#WARNINGS[@]} -ne 0 ]; then
  bold "Warnings (did not affect the answer)"
  for w in "${WARNINGS[@]}"; do printf '  · %s\n' "$w"; done
  echo
fi

if [ ${#BLOCKERS[@]} -eq 0 ]; then
  cat <<EOF
$(bold "[wif-probe] PASS")

  A signed-in human's Entra token was accepted as the assertion, and the
  resulting short-lived token can call Claude. The design holds: shotAI can talk
  to api.anthropic.com directly with no API key on anyone's machine.

  Values shotAI needs (none are secret — the JWT is what authenticates):
    federation_rule_id  $FDRL
    organization_id     $ORG_ID
    service_account_id  $SVAC
    workspace_id        $WRKSPC
    entra_tenant_id     $TENANT_ID
    entra_audience      api://$APP_ID

  Next, in this order:
    1. Add an App Role (e.g. shotAI.User) on a shotAI app registration and
       tighten the rule with a CEL condition requiring it. That assignment
       becomes who may use the AI features.
    2. Set a spend cap on the workspace — every user shares its limits.
    3. Build the Swift side: ASWebAuthenticationSession → this exchange →
       Authorization: Bearer, refreshing ~2 min before expiry.

  DO NOT DELETE THE APP REGISTRATION. On a PASS it stops being scratch: the
  federation rule matches its ID as the audience, and it is the app your users
  actually sign in to. \`az ad app delete --id $APP_ID\` would break the rule
  and revoke everyone at once. Rename it in the Entra portal if the probe name
  bothers you; the ID is what matters and renaming does not change it.
EOF
  exit 0
fi

printf '\033[31m%s\033[0m\n' "[wif-probe] FAIL — ${#BLOCKERS[@]} blocker(s)"
for b in "${BLOCKERS[@]}"; do printf '  · %s\n' "$b"; done
printf '\n  Entra objects created by this probe remain. Safe to remove ONLY while no\n'
printf '  federation rule references this app as its audience:  az ad app delete --id %s\n' "$APP_ID"
exit 1
