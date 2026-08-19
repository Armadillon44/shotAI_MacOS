# Entra SSO via Workload Identity Federation

How shotAI can call the Anthropic API with **no API key on any machine and no
gateway in the path**. Users sign in with Microsoft Entra ID; their token is
exchanged for a short-lived Anthropic token; access is an Entra role assignment.

Proven end to end 2026-08-19. Tracked in
[#69](https://github.com/Armadillon44/shotAI_MacOS/issues/69).

> **Optional, and off by default.** shotAI remains bring-your-own-key. Federation
> is an internal deployment mode; with nothing configured the app behaves exactly
> as it always has. See [Configuration](#configuration).

---

## Why

Bring-your-own-key does not scale inside an organization. It means provisioning,
rotating, and revoking a long-lived secret per person, and every one of those
keys sits on a laptop. Federation replaces the key with a sign-in:

- **Nothing long-lived to leak.** The minted token lives ~10 minutes.
- **Revocation is an Entra assignment**, effective on the next refresh. No app
  change, no key rotation, no redeploy.
- **No gateway.** Screenshots and prompts go straight from the client to
  `api.anthropic.com`. There is no proxy to secure, log, or pay for. This was
  the point of testing federation rather than building the originally-proposed
  API gateway.

## The flow

```
shotAI  ──sign in──▶  Entra ID  ──▶  delegated v2.0 access token (JWT)
   │                                   aud = <APP_ID>, roles = ["shotAI.User"]
   │
   └── POST api.anthropic.com/v1/oauth/token
         grant_type = urn:ietf:params:oauth:grant-type:jwt-bearer
         assertion  = the Entra JWT
         + federation_rule_id, organization_id, service_account_id, workspace_id
              │
              └──▶  sk-ant-oat01-…  (short-lived)  ──▶  Authorization: Bearer
```

**This was undocumented.** Anthropic documents Workload Identity Federation only
for *machine* workloads: Azure managed identities via IMDS, AKS workload
identity, GitHub Actions OIDC. A laptop has none of those. Whether a **human's**
Entra token is accepted as the RFC 7523 assertion was an open question, answered
by `Scripts/wif-probe.sh`.

That probe is also the regression test. It refuses to report success unless the
assertion is demonstrably user-derived, because an app-only token from
`az login --service-principal` carries byte-identical `iss`/`aud`/`tid` and would
otherwise "prove" a design nobody tested.

## Access control

Access is gated on an Entra **App Role**, enforced by a CEL condition on the
federation rule:

```
claims.tid == "<TENANT_ID>" && "roles" in claims && "shotAI.User" in claims.roles
```

**The middle clause is load-bearing, not redundant.** Entra **omits** `roles`
entirely for an unassigned user rather than sending an empty array. In CEL,
indexing a map with an absent key is a **runtime error**, not `false`, and
Anthropic documents nothing about what their evaluator does with one.

`"roles" in claims` is a map **operator**, not a macro, so it needs no `has()`
support, and it lets `&&` short-circuit. Verified: an unassigned user receives a
clean `401`, not a 500 or a hang.

Restating `tid` inside the expression is also deliberate. Nothing documents
whether the Console's Pattern-match ↔ CEL toggle preserves the separate claim
conditions, and losing the tenant pin would widen access rather than narrow it.

Without the role clause the rule matches on `tid` alone, which authorizes every
identity in the tenant. Anthropic's own Entra guidance names this gap: *"Every
identity in your tenant can request a token for the registered audience, so
`audience` and `tid` alone do not identify a specific workload."*

## Configuration

Six values are needed at runtime. None is a credential — the JWT is what
authenticates — but together they map an organization's Entra tenant and
Anthropic org, so **they are deliberately not in this repository, which is
public**:

| Value | Shape |
|---|---|
| federation rule | `fdrl_…` |
| organization | uuid |
| service account | `svac_…` |
| workspace | `wrkspc_…` |
| Entra tenant | uuid |
| Entra audience | the app registration's **bare app-ID GUID** |

They belong in an MDM-delivered configuration profile (see [`Intune/`](../Intune/))
or a build config, never in source. The probe caches them at
`~/.config/shotai/wif-probe.env`, mode 0600, outside the repo.

## Operational notes

Each of these cost real debugging time.

- **A federation rule's claim conditions cannot match `roles`.** The Console's
  "Additional claim conditions" is `map<string,string>` and `roles` is always a
  JSON array. Configuring it there saves cleanly and then denies everyone,
  silently. CEL is the only mechanism.
- **Expected audience must be the bare app-ID GUID**, no `api://` prefix.
  Leaving it blank does not disable the check; it substitutes Anthropic's default
  audience, which an Entra token never carries.
- **Use the v2.0 issuer** (`https://login.microsoftonline.com/<TID>/v2.0`). The
  Console's issuer selector defaults to v1, and the app registration needs
  `requestedAccessTokenVersion: 2`.
- **`az account get-access-token` has no `--force-refresh`**
  ([Azure/azure-cli#17578](https://github.com/Azure/azure-cli/issues/17578), open
  since 2021) and a bare `az login` does not help, because it mints an
  ARM-scoped token under a different cache key. Use
  `az login --scope "api://<APP_ID>/.default"`, which is what the probe's
  `--fresh` does. A newly assigned role otherwise never appears, and it looks
  exactly like a broken rule.
- **`check_jti` and `max_jwt_lifetime_seconds` are issuer-level**, shared by
  every rule on that issuer. Never disable `check_jti` to make a test pass.
  Moot for Entra anyway, which emits `uti` rather than `jti`.
- **Elevated Entra directory roles bypass app assignment gates** and still
  receive a token, just with no `roles` claim. Verifying only against an admin
  account proves nothing about ordinary staff.
- **Never delete the audience app registration.** The federation rule matches its
  ID, so deleting it revokes everyone at once. Renaming is safe; the ID does not
  change.
- **Graph rejects creating an `oauth2PermissionScope` and a
  `preAuthorizedApplications` reference to it in the same PATCH.** Two calls,
  scope first. The failure is `Permission Id that cannot be found in the
  AppPermissions sets`, at PATCH time.
- **`AADSTS500011` is a different failure** — the audience does not resolve in
  the tenant, meaning no identifier URI or no service principal. The two get
  conflated because a half-applied setup produces both at once, but they have
  separate causes and separate fixes.

## Changing a rule safely

Anthropic selects federation rules **by ID**; there is no implicit rule search
and no precedence between rules. **A parallel rule is therefore invisible to
production traffic**, which makes a zero-downtime dry run possible:

```
create app role → assign a normal (non-admin) user
    → prove `roles` reaches the JWT
    → create a PARALLEL rule with the new match
    → prove it ACCEPTS an assigned user
    → prove it DENIES an unassigned one
    → only then edit the live rule
    → re-prove both directions
```

The probe supports this directly: `FDRL=<rule> bash Scripts/wif-probe.sh`
overrides the cached rule ID for one run, so the same assertion can be replayed
against two rules with the match block as the only variable.

Two rules of thumb from doing this the hard way:

**A PASS proves acceptance, never rejection.** A `tid`-only rule accepts every
user in the tenant and passes identically to a correctly-scoped one. Only a
negative run against a user who *should* be denied shows that a rule
discriminates at all. This was misread twice during the original work.

**Read the server-side log before forming a hypothesis.** Every denial returns
the same opaque `401 authentication_error` by design, so an attacker cannot probe
rule configuration. The real reason exists only in **Console ▸ Settings ▸
Workload identity ▸ History**, which names the issuer and rule evaluated, the
claims inspected, and the check that failed. External probing produced two
confident, wrong diagnoses (rate limiting, then JWT lifetime) while that page had
the true cause both times.

## Cost

Every user's token targets the **same service account and workspace**, so they
share its limits.

- **Unset workspace rate limits inherit the organization's full limits.** The
  default state is open. This is the real exposure and the control that bounds a
  runaway loop within minutes.
- A workspace **spend** limit is monthly, and its enforcement is not documented
  by Anthropic — no status code, error type, or message is published. Treat it
  as the bill ceiling and rate limits as the burn-rate brake.
- **Per-user spend is not attributable.** With one shared service account, the
  Usage API's `service_account_id` dimension is a constant. Per-cohort
  attribution requires N rules → N service accounts → N workspaces, partitioned
  by app role; workspaces cap at 100 per org, so per-employee does not scale.

See [#71](https://github.com/Armadillon44/shotAI_MacOS/issues/71).

## Client behavior

- The exchange keeps succeeding when quota is exhausted; the documented
  `/v1/oauth/token` error table has no 402, 403, or 429 row. Users sign in fine
  and fail at generation time, so **the error surface belongs in the SOP path,
  not the auth path**.
- `429` is ambiguous under federation: transient throttle or spent budget. There
  is no documented error type for a spend cap, so branch on `retry-after` rather
  than asserting a cause. See
  [#72](https://github.com/Armadillon44/shotAI_MacOS/issues/72).
- Token lifetime is `min(rule lifetime, 2 × remaining JWT life)`, floor 60s.
  Refresh roughly two minutes before expiry.
