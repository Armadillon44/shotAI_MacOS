# Conformance fixtures

Language-neutral cases both platforms run against their own `project.json` codec.

`project.json` round-trips between the macOS and Windows apps, so the rules for
what a malformed, unknown or out-of-range value degrades to are a **shared
contract**. Those rules are written twice, in two languages, and until this
suite nothing checked that the two agreed. Step 2 (`contract/brand.json`)
removed the class of drift where a shared *value* is edited on one side;
this removes the class where a shared *behaviour* is.

## The assertion surface

**Decode the input, encode it again, and compare the resulting JSON.** Not the
store — no `updatedAt` bump, no disk — just the codec. What a platform writes
back for a given input IS the contract; anything else is a platform's own
business.

## A case

```json
{
  "name": "unknown-root-key-round-trips",
  "why": "One sentence on what breaks if this stops holding.",
  "status": "agreed",
  "input":  { "id": "p", "...": "a whole project.json" },
  "expect": {
    "somethingNew":  { "nested": [1, 2] },
    "displayScale":  { "$absent": true }
  }
}
```

- `expect` maps a **dotted path** in the re-encoded JSON to the value required
  there. `{"$absent": true}` requires the path to be missing — which is how
  "this key must not be written" is expressed, and it is a real requirement:
  a default written explicitly is a byte-level change to every existing file.
- Paths index arrays with `steps.0.kind`.

## `status`

| | |
|---|---|
| `agreed` | both platforms must pass. A failure is a bug. |
| `open` | a **known** divergence. Each harness reports it and does not fail. |

When an `open` case **passes on one platform**, that harness says so — otherwise a
divergence that gets fixed keeps its `open` label forever and nobody re-checks by
hand. It is not proof of resolution: a case is open because at least one platform
diverges, so both sides must pass before the status is flipped.

`open` is the point of the field, not a loophole. These divergences already
exist; writing them here turns a paragraph in a document nobody re-reads into
executable, reviewable state. Every `open` case names the issue tracking it, and
resolving one means flipping the status — so the suite tells you what is left
rather than going quietly green.

Add a case by writing the JSON. Both harnesses discover files, so neither needs
touching:

- macOS — `Packages/ShotModel/Tests/ShotModelTests/ConformanceTests.swift`
- Windows — `src/main/conformance.test.ts`

## What this does not yet check

That the two repos hold the *same* fixtures. `contract/brand.json` gets this for
free — its generated output stamps the contract's sha256, so a mismatch shows up
in a diff — but a directory of cases has no generated artifact to stamp.

Until a check sees both trees at once, adding a case means adding it to **both**
repos in the same change. A case present on one side only still does useful work
there; it just is not yet a shared assertion.
