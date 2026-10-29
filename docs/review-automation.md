# Advisory review and PR triage

This proposal starts in observation mode. It adds review guidance and informational
PR labels, with **no automatic merge, queue, approval, branch update or code repair**.
The repository is `orkunisitmak/clipboardline`, GitHub repository ID **1425566096**.
The previous `clipboardline-desktop` name is a compatibility redirect; do not rename
signed update wire identities as part of automation setup.

## What the files do

- `.coderabbit.yaml`: Turkish PR summaries and reviews, incremental review on push,
  draft reviews disabled, and repository-specific Mac/Windows/privacy instructions.
  Generated Windows locales and dependency lockfiles remain in review scope.
  Automatic approvals, author approval commands, fixes, generated tests/docstrings,
  conflict resolution, post-merge agents, third-party tracker writes and automatic
  label/reviewer assignment are disabled. Repository inheritance and cross-repository
  context are not configured. These settings are guidance, not an access-control
  boundary against a contributor changing their branch's review configuration.
- Issue enrichment may suggest duplicate/related issues, code context and assignees.
  Issue label application and implementation planning are disabled. Suggestions need
  human review; neither product is configured to implement or close issues.
- `.mergify.yml`: six rules that only toggle informational `triage/*` PR labels.
  There are no merge/queue/protection rules, imported configurations, bot accounts,
  auto-merge settings or actions that edit source. All nine documented commands are
  deliberately blocked with contradictory sender conditions during this phase.
- `scripts/test-review-automation.py`: offline schema and adversarial policy tests.
  It is not installed in the application and is not a live Mergify simulator.
  Reviewer-only dependencies are pinned in `scripts/requirements-review-automation.txt`.
  Existing CI workflows and branch protection are unchanged by this proposal.

| Label | Meaning after an approved activation |
| --- | --- |
| `triage/needs-maintainer` | Every open PR into `main` still needs a human decision. |
| `triage/dependencies` | The real Dependabot account or a dependency/config manifest changed. |
| `triage/sensitive` | Application, test, native helper, contract, update identity, policy or script paths changed. |
| `triage/conflict` | The PR currently conflicts with its base. |
| `triage/ci-attention` | A check is failed, pending or stale. Missing checks do not create a ready label. |
| `triage/localization` | Shared Apple translation catalogs or the generated Windows catalog changed. |

Mergify's `files` includes old and new paths for renames. Path labels therefore also
identify a sensitive file moved elsewhere. All labels are navigation aids; anyone
able to change a label can affect its display. No label, PR title, diff size, bot
identity or AI review gives permission to merge. There is no automatic lane even
for a one-line documentation change. Feature, mixed, refactor, dependency and
security/configuration changes require Orkun's explicit decision.

## Current repository checks and limitations

The existing jobs are `test-and-community-build` (Mac XCTest, localization and Dev
build), `windows` (Node and native source/packaged/installed/updater acceptance), and
`publication-guard` (public-source audit and history secret scan). Pages `deploy` is
a publication workflow, not a substitute for these checks. Windows uses path
filters: a configuration-only PR may have no Windows run. Missing, skipped, stale,
cancelled or pending is not passing evidence for an application change.

Before merging an application PR, a reviewer must re-fetch its **current head SHA**,
base/integration state, trusted GitHub Actions check source and full applicable
results. Bind native parity artifacts to that source revision. A successful old
head or base-branch run does not verify the PR. Require a fresh maintainer decision
after code changes; do not infer it from an old approval or a mutable label.

Known inherited blockers from the repository review are not fixed here:

- `windows.yml` runs `npm audit` followed by `npm test` in one PowerShell step; a
  successful final command can mask an audit failure. Green CI alone is insufficient
  until exit-code propagation is repaired and verified.
- The reviewed lockfile includes Electron 44.9.0 and fast-uri 3.1.8 with public
  advisories. Dependency resolution and native compatibility need separate review.
- The connected integration previously received HTTP 403 reading branch-protection
  details. Protection was preserved; its full required-check/review/bypass settings
  were not certified. Do not activate an automatic lane on that assumption.

## Activation is a separate, approved operation

Creating or merging a YAML file does not install a GitHub App. This draft must stay
unmerged until Orkun approves the policy. The coordinating setup task separately
obtains action-time approval for each App's actual installation screen and selected
repository access. Select **only** `orkunisitmak/clipboardline`, never all current
and future repositories. Do not create a token, accept a paid plan/trial/usage-based
billing, alter branch protection, enable a merge queue or turn on dashboard merge
automation as part of this phase.

The products request broad, persistent permissions even when our policy only uses
review/labels. YAML cannot narrow a GitHub App's granted scopes. The installation
screen at approval time is authoritative; stop if the scopes differ from the
reviewed disclosure. Current official documentation lists:

| App | Documented permissions to disclose before installation |
| --- | --- |
| CodeRabbit | Read: Actions, discussions, members, metadata and merge queues. Read/write: checks, repository code/contents, commit statuses, issues, pull requests and workflows. Sign-in additionally describes read access to organizations/teams and account email addresses. |
| Mergify | Read/write: Actions, checks, contents, deployments, issues, Pages, pull requests and workflows. Read: repository administration, commit statuses, metadata, merge queues and organization administration where applicable. |

CodeRabbit's `allow_non_org_members` control only restricts comment chat in GitHub
organization repositories; it must not be treated as owner authorization in this
personal repository. Likewise, CodeRabbit documents that a successful check on a
merge-group commit may be published without another review. AI checks are not the
trusted human authorization channel.

After separate App-access and policy approvals, enable only advisory reviews and
Mergify Workflow Automation's label rules. Keep merge/queue/automatic repair/CI retry
and quarantine products off. Validate resolved service configuration, one harmless
test PR, incremental review after a push, label toggling and command denials before
processing existing contributions. Do not use existing open PRs as mutation probes.
Default-branch policy is trusted only after maintainer review; a contributor's
modified YAML, instructions or self-applied labels cannot authorize extra powers.

## Any later automatic lane needs another reviewed policy

No automatic lane is implemented by this change. A future proposal must first fix
the audit gate, verify protection/expected CI App identity, dismiss stale approvals
and require approval of the latest push without adding a bypass. It needs a narrow
allowlist that excludes dependencies/lockfiles, `.github/**`, automation settings,
code/guidelines, executable documentation, application/native/security/update code,
and mixed changes. Bind authorization and passing applicable CI to the same current
head and tested integration revision. Unknown/truncated file inventories, missing
permissions, stale reviews or checks, conflicting branches and unknown paths must
deny automation. A label and a line-count threshold are not adequate gates.

## Reproduce validation without service access

```sh
python3 -m venv /tmp/clipboardline-review-tools
/tmp/clipboardline-review-tools/bin/python -m pip install --only-binary=:all: \
  -r scripts/requirements-review-automation.txt
/tmp/clipboardline-review-tools/bin/python scripts/test-review-automation.py
```

For full JSON Schema validation, independently download the two official schemas
below into a local directory as `coderabbit-schema.json` and `mergify-schema.json`,
then pass `--schema-dir /path/to/schemas`. Keep downloaded schemas and test outputs
outside the tracked public source. No network or GitHub calls are made by the test.

The tests evaluate the exact deployed condition subset against docs, code,
dependencies, generated translations, conflict, pending/failed/stale CI, sensitive
renames, owner/bot/external command senders, closed/wrong-base PRs, and forged AI
approval/labels. Negative tests reject merge/queue/import settings (including empty
auto-merge conditions), approval/code-repair actions, ready labels, unknown
conditions and duplicate YAML keys. Live Mergify condition parsing/simulation and
CodeRabbit delivery remain unverified until the approved Apps are available.
The local test is not wired into required CI by this draft; policy enforcement
still depends on trusted maintainer review and existing GitHub protections.

## Cost and issue-management scope

On 2026-10-27 the official pricing pages describe free CodeRabbit reviews for public
repositories and a free Mergify Open Source plan. This does not guarantee every
agent, Triage UI, security scan or account-specific add-on is free. No paid feature
or credential is provisioned here. If an intended capability requires payment,
leave it disabled and report it instead of subscribing.

CodeRabbit can review PRs and enrich issues with context/suggestions. Mergify's
Workflow Automation rules act on **pull requests**, not a general issue backlog.
Issue prioritization, accepting duplicate suggestions, assigning work, accepting a
solution and closing an issue remain human decisions. Neither product is promised
to autonomously resolve bugs. Configure additional issue automation separately
after observing useful results and approving its exact permissions and behavior.

## Required service-side verification before activation

CodeRabbit reads the configuration on the PR branch. An external contributor can
propose a different `.coderabbit.yaml`; this file alone cannot authoritatively lock
off approvals, repair agents, issue planning or other write-capable features.
Before activation, the repository owner must inspect the service's **resolved**
configuration, configuration precedence, command eligibility and effective locks
against a harmless PR that changes those fields. Verify that branch-controlled
settings cannot enable code writing, automatic approvals or additional integrations.
Dashboard defaults that are overridden by PR YAML are not such a lock.

CodeRabbit documents higher-priority organization/workspace global overrides, but
availability is plan-dependent. Do not assume those controls are included in the
free public-repository service, start a trial or buy a plan to obtain them. If no
authoritative service-side control is available under the approved free setup,
leave the integration inactive and report that limitation to Orkun. A passing local
schema or the tests in this PR does not establish service-side enforcement.

The owner must separately verify that Mergify reads the reviewed default-branch
policy, its dashboard has no inherited auto-merge/queue settings, and its command
restrictions resolve to denial. Preserve GitHub's independent human-review and
current-SHA CI protections; do not add either App as a bypass actor. Features and
mixed changes still need Orkun's approval. These checks require approved App access
and GitHub authentication; they are not completed by opening this draft.

## Official references checked 2026-10-27

- [CodeRabbit schema](https://coderabbit.ai/integrations/schema.v2.json)
- [CodeRabbit configuration](https://docs.coderabbit.ai/reference/configuration)
- [CodeRabbit GitHub permissions](https://docs.coderabbit.ai/platforms/github-com)
- [CodeRabbit issue enrichment](https://docs.coderabbit.ai/issues/enrichment)
- [CodeRabbit pricing](https://www.coderabbit.ai/pricing)
- [Mergify schema](https://docs.mergify.com/mergify-configuration-schema.json)
- [Mergify file format](https://docs.mergify.com/configuration/file-format/)
- [Mergify conditions](https://docs.mergify.com/configuration/conditions/)
- [Mergify labels](https://docs.mergify.com/workflow/actions/label/)
- [Mergify command restrictions](https://docs.mergify.com/commands/restrictions/)
- [Mergify auto-merge semantics](https://docs.mergify.com/merge-protections/auto-merge/)
- [Mergify permissions](https://docs.mergify.com/security/)
- [Mergify pricing](https://mergify.com/pricing)
