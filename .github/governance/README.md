# CI-only draft for CodeRabbit policy validation

Parent: RepoKan/RepoTestUse PR #1, head 94c6f55f765e5d3bbe2d5aa424fc28b84d2096ad.
This change does not modify the existing .coderabbit.yaml or main.
A separate independent human reviewer must review this policy gate.
The validator and its tests are on an untrusted PR head until adopted into
a protected trusted baseline. This is not complete independent enforcement.

The workflow runs a real Ruby YAML parser and negative policy tests. It rejects
higher merge/security risks, author approvals, unsafe overrides, ambiguous YAML,
and missing sensitive-path protections. A final gate explicitly fails when the
validation job is skipped, failed, cancelled or tested on a different head.
GitHub branch protections, human reviews, and final merges are NOT altered.
