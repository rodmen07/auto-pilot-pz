# AutoPilot: the GitGuardian merge-gate decision

> **STATUS: DECIDED 2026-08-10 by the owner — "deliberately advisory".** The
> `GitGuardian Security Checks` context stays an **advisory** check on pull requests and is
> **NOT** promoted to a required status check on `main`. Branch protection keeps requiring
> exactly one context, `lint-and-test`.
>
> **Nothing was changed to record this.** No `gh api -X PUT .../protection` call was made by
> the increment that wrote this file; section 4 quotes the protection as it already stood, on
> the day the decision was recorded, and that read IS the evidence that nothing moved.
>
> **This is an ANSWER, not an open question.** The finding it closes was opened 2026-08-07 by
> a DevSecOps posture read and is exactly the kind of thing a later sweep will re-derive from
> the API — a repo where a security scanner reports on every PR and gates none of them looks
> identical whether that is an oversight or a decision. It is a decision. A sweep that lands
> here should read section 5, which names the conditions that would genuinely reopen it, and
> stop. "The finding is still visible in the API" is not one of them.

## 1. The question

`GitGuardian Security Checks` runs on every pull request in this repository and has reported on
every recent one. It is not in the required-context list, so its verdict does not gate a merge:
a pull request whose secret scan goes **red is still mergeable** as far as branch protection is
concerned. The finding asked whether to promote it to a required context.

This is the shape the autodev SKILL.md names as precedent under "Repo posture" — the sibling
`calm-daily-coach` repo required only a legacy `lint-and-build` context for a while, so its
typecheck and tests never blocked a merge. Advisory checks that look like gates are worth
finding. This one was found, and then it was decided rather than fixed, which is a different
outcome from being forgotten.

## 2. The answer, and why

**Keep it advisory.** The reason is a deadlock this repository cannot escape from.

`GitGuardian Security Checks` is posted by an external GitHub App, not by a job in
`.github/workflows/`. A required context is required *to be reported green*, not merely
*to not be red*: if the App ever stops posting — an outage, a permissions change, an
installation lapse, a repository transfer — every pull request stalls at
`mergeStateStatus=BLOCKED` waiting for a check run that will never exist. `gh pr checks
--watch` cannot see it either, because there is nothing to watch; that failure mode is
already written down as autodev lesson L-039.

`enforce_admins=true` on this branch (section 4) is what makes that terminal rather than
annoying. With admin enforcement on there is no "merge anyway" for anyone, including the
repository owner. Recovering would mean editing branch protection under an outage — the exact
setting the finding proposed to harden — and the automated merge flow that ships this project
would be dead in the meantime.

Weighed against that: what a required GitGuardian context would actually buy is *enforcement of
a rule this project already follows by convention*, on a repository whose secret exposure is
already gated at push time by a different, first-party control (section 6). That is a small
gain for a whole-pipeline failure mode.

## 3. The accepted risk, in plain words

**A pull request whose secret scan goes RED can be merged, and nothing in the repository will
stop it.** That is a known, chosen state, not an oversight.

If a commit on a branch contains something GitGuardian recognises as a secret, the check turns
red, the red is visible on the pull request page, and `gh pr merge` will still succeed. The only
thing standing between that red and a merged secret is a human or an agent reading the check.
There is no technical control behind the convention in section 6; conventions are not gates, and
this one is being trusted deliberately.

A second, sharper edge is worth stating because this repository has already been bitten by it:
GitGuardian scans **every commit in the pull request, not the final tree**, so a secret removed
by a later commit on the same branch leaves the check red — and, symmetrically, a secret that
was ever committed on the branch is in the branch's history even if the merged squash does not
contain it. That is recorded in the backlog as an operational fact from PR #135/#136. Under this
decision, that red is advisory too.

## 4. Evidence, read live on 2026-08-10

Branch protection on `main`, unchanged by this decision
(`gh api repos/rodmen07/auto-pilot-pz/branches/main/protection`):

```json
"required_status_checks": {
  "strict": true,
  "contexts": ["lint-and-test"],
  "checks": [{"context": "lint-and-test", "app_id": 15368}]
},
"required_signatures":  {"enabled": false},
"enforce_admins":       {"enabled": true},
"required_linear_history": {"enabled": false},
"allow_force_pushes":   {"enabled": false},
"allow_deletions":      {"enabled": false}
```

One required context, `lint-and-test`, `strict=true`, `enforce_admins=true`. That is the same
state the 2026-07-24 reconciliation recorded and the same state the 2026-08-07 finding measured.

Alert counts, both `0`:

```
gh api repos/rodmen07/auto-pilot-pz/secret-scanning/alerts --jq length   ->  0
gh api repos/rodmen07/auto-pilot-pz/dependabot/alerts      --jq length   ->  0
```

**Read the instrument's scope before its verdict.** A `0` from a scanner that is switched off is
indistinguishable from a `0` from a clean repository, so the feature state was read too
(`gh api repos/rodmen07/auto-pilot-pz --jq .security_and_analysis`):

```json
{"secret_scanning":                        {"status": "enabled"},
 "secret_scanning_push_protection":        {"status": "enabled"},
 "dependabot_security_updates":            {"status": "enabled"},
 "secret_scanning_non_provider_patterns":  {"status": "disabled"},
 "secret_scanning_validity_checks":        {"status": "disabled"}}
```

So the two zeros are genuine clean reads rather than blank ones — with one honest caveat:
`non_provider_patterns` is **disabled**, so GitHub's own `0` covers provider-recognised secret
formats only. A generic credential (a homegrown token, a password in a config example) is
outside what that particular `0` is saying anything about. GitGuardian's broader detectors are
part of why it is worth keeping as an advisory signal at all.

**The zeros are context, not the reason.** They are what makes today's accepted risk small:
there is nothing currently exposed for a missing gate to have let through. That number can
change tomorrow, and this decision would not change with it. **The decision is about the GATE
— whether an externally-posted context may hold the merge queue hostage — and not about the
current alert count.** A future non-zero alert count is a security incident to be handled on its
own terms; it is not, by itself, an argument that this gate should have been required.

## 5. What would reopen this

Not "a sweep noticed the check is advisory again". These:

- **The accepted risk is actually spent:** a pull request is merged with `GitGuardian Security
  Checks` red. That is the event this decision licenses, and the first occurrence should be
  recorded here with its PR number rather than absorbed silently — the point of an accepted risk
  is that spending it is visible.
- **The deadlock stops being terminal:** `enforce_admins` is turned off, or GitHub gains a way
  to require a context that degrades to "skipped" instead of "pending" when its App does not
  report. Either removes the reason in section 2, and the decision should then be re-taken on
  its merits rather than inherited.
- **The convention in section 6 is observed failing**, i.e. someone finds a merge that went
  through a red scan because nobody looked. That falsifies the compensating control, and the
  decision was made partly on the strength of it.

## 6. What this decision does NOT say

- **It does not say secrets are ungated.** `secret_scanning_push_protection` is **enabled**
  (section 4), and that is a first-party, non-advisory control: GitHub blocks a push containing a
  provider-recognised secret before a pull request exists at all. What stays advisory is the
  *second* scanner's *merge-time* verdict, which is a narrower thing than "nothing gates secrets".
- **It does not say a red GitGuardian may be ignored.** The standing convention in this project
  is that a red secret scan blocks the merge anyway, enforced by whoever is merging rather than
  by protection. The precedent is on the record: on 2026-08-08 a run hit a red GitGuardian on
  PR #135 over a deliberately fake auth header in a test fixture, and instead of merging — which
  protection would have allowed — it closed the PR and re-shipped the work from a fresh branch as
  PR #136. Note honestly what that is: a convention, not a control. Section 3 is the price.
- **It does not remove GitGuardian.** The check keeps running on every pull request. An advisory
  signal that is read is worth considerably more than no signal, and its output is why the
  PR #135 episode was caught at all.
- **It does not change `lint-and-test`.** That context remains required, `strict=true`, and it is
  the gate that actually holds this project's merges to a bar.
