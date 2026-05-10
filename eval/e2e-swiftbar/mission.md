# Autoresearch Mission: MLX Server E2E SwiftBar Validation

## Mission slug
`mlx-server-e2e`

## Objective
Prove that clicking "Start [model]" in SwiftBar produces a correctly-functioning shim stack for all 4 configured models, as measured by an automated evaluator covering instruction-following, performance, no-refusal, and semantic coherence.

## Spec reference
`.omc/specs/deep-interview-mlx-server-e2e-autoresearch.md`

## Models under test (in order)
1. gemma-26b-moe — baseline 92.6 tok/s, floor ≥ 74 tok/s
2. gemma-31b — floor ≥ 80% of first-run baseline
3. mistral-medium — floor ≥ 80% of first-run baseline
4. scout — advisory only (known flaky, tracked but not blocking)

## Pass condition
`evaluator.json` → script outputs `{"pass": true, ...}` when gemma-26b-moe, gemma-31b, and mistral-medium all pass all checks. Scout result recorded separately.

## Max runtime
4 hours per autoresearch run (model loads are slow; 4 models × ~10 min each + checks).

## Evaluator
See `evaluator.json` and `evaluate.sh` in this directory.

## Iteration strategy
- Iteration 1: Validate osascript menu path (SwiftBar item index + submenu navigation). Establish first-run tok/s baselines for gemma-31b, mistral-medium, scout.
- Iteration 2+: Use stored baselines as performance floors. Fix any failing checks.
- Same-failure-3x: Surface as a known gap in `gaps.jsonl` and `decision-log.md`.
