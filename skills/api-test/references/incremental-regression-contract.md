# Incremental Regression Contract

A versioned catalog lists every active scenario, exact scenario hash, typed impact keys, and real upstream/downstream relations.

For `FULL`, select the entire catalog. For `IMPACT`, seed scenarios whose impact keys intersect `changedImpactKeys` or prior failed assertions, close over scenarios sharing affected keys, then traverse relevant catalog edges to the declared depth. Selected IDs must exactly equal the computed closure.

Use `FULL` when any declared trigger is active: `impact-unknown`, `catalog-stale`, `shared-foundation-change`, `test-infrastructure-change`, `multi-domain-change`, `unexpected-outside-impact-failure`, `release-baseline`, or `policy-required`.

For fix verification, run prior reproducers first. If the defect remains, stop remaining downstream work. If it passes, execute the exact shared/upstream/downstream closure. A targeted PASS never claims that the entire catalog ran.
