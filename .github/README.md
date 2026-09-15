# Issue triage

[Copilot Triage](https://github.com/crmne/copilot-triage) assesses new and
reopened issues and new discussions. It adds up to two labels and can ask for
one missing fact or answer from the configured documentation and source files.
It reads the report and latest five comments. Maintainers handle duplicates,
closure, and removing obsolete labels. Comments do not trigger model calls.

Edit `triage.yml` for labels, replies, sources, and response policy. The action
is pinned in `workflows/issue-assessment.yml`; its regression tests live in the
shared repository. Keep `COPILOT_ISSUE_ASSESSMENT_ENABLED=true` and configure the
`COPILOT_GITHUB_TOKEN` secret to enable it.

To reassess an issue without publishing changes:

```sh
gh workflow run issue-assessment.yml -f kind=issue -f number=123 -f dry_run=true
```

Use `kind=discussion` for a discussion or `dry_run=false` to apply the result.
Unchanged prompts reuse cached answers. A party-popper reaction marks a
completed assessment, including one needing no reply. Bot-authored reports
are skipped; model failures stay in the job summary.
