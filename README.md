# Regression Impact Verifier

A read-only PowerShell helper that turns a Git diff or explicit changed-file list into a conservative manual regression checklist. It is intended to reduce repetitive changed-file and existing-test inventory work before a human review.

## Problem

After a change, a reviewer must repeatedly identify changed areas, look for plausibly related existing tests, and decide where a manual smoke check is still needed. This information is scattered across the diff, repository layout, test naming, and package scripts.

## What it does

The verifier scans the repository and reports, for each changed file:

- file kind and likely top-level area;
- deterministic relationships to existing test filenames or test content;
- configuration changes that merit manual smoke review;
- package test/check/lint commands discovered for a human to consider.

It uses Git metadata, `package.json`, test paths, filenames, and test contents. It does not use an LLM and does not run tests.

## What it does not do

`RELATED_TEST_FOUND` means only that a related-looking existing test was found. It does not mean the change is covered, tested, safe, adequate, or regression protected. The tool does not measure coverage, establish test adequacy, infer runtime behavior or product risk, generate tests, or replace human QA.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Git only when using the default working-tree mode or `-BaseRef`
- No package installation or Docker/service is required

## Usage

From the repository root:

    .\verify-regression-impact.ps1
    .\verify-regression-impact.ps1 -BaseRef HEAD~1
    .\verify-regression-impact.ps1 -ChangedFile @('src/app.js', 'config/example.json')
    .\verify-regression-impact.ps1 -IncludeUntracked -OutputFormat Json -RedactPaths
    .\verify-regression-impact.ps1 -NoGit -OutputFormat Json

The default mode inspects unstaged and staged changes. `-BaseRef` compares `BaseRef..HEAD`. `-ChangedFile` accepts an explicit array and avoids Git discovery. `-OutputPath` can save the report; the script does not create or modify repository files unless that output path is explicitly supplied.

## Classifications

- `RELATED_TEST_FOUND` 窶・a deterministic filename/content relationship to an existing test was found; this is not a coverage measurement.
- `NO_RELATED_TEST_FOUND` 窶・a source-like change has no deterministic relationship to the discovered tests.
- `MANUAL_SMOKE_RECOMMENDED` 窶・a configuration or other behavior-sensitive change needs human review.
- `UNKNOWN` 窶・the tool declines to infer coverage for documentation, private data, or an unrecognized file kind.

Each item includes its evidence and reason. A changed test is not treated as proof that the source behavior is covered.

## Privacy and safety

The tool is read-only with respect to Git and the repository: it does not stage, reset, commit, delete, rename, overwrite, execute tests, or execute suggested commands. It reports relative paths by default. Use `-RedactPaths` when saving JSON for sharing. It excludes `.git`, `.claude`, `node_modules`, and `private-data` from test discovery; do not pass private absolute paths as explicit inputs to a report intended for publication.

## Limitations

Filename/content relationships are conservative heuristics. A related test may not exercise the changed behavior, a valid relationship may be missed, and the related-test list is intentionally capped. Runtime configuration effects, semantic diff risk, coverage, and test adequacy remain human responsibilities.

## License

PolyForm Noncommercial License 1.0.0. See `LICENSE`. Version and release status are recorded in `VERSION.md`. This directory is a public-ready candidate; it has not been published.
