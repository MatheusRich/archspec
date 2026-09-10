# Issue assessment

The source workflow is `workflows/issue-assessment.md`. After changing it,
regenerate its committed lock file with `gh aw compile issue-assessment`.
Run `node --test .github/tests/*.test.cjs` to check completion and retry behavior.

The agent uses the `github` and `safeoutputs` CLI bridges. Shell access is
limited to those commands. This avoids the native Copilot MCP client's protocol
negotiation failure with the gateway while preserving read-only GitHub access
and reviewed safe outputs.

A rocket reaction marks a completed assessment. The activation check only reads
reactions; the completion job adds the marker after the requested safe outputs
succeed. Empty outputs, missing tools, incomplete assessments, or failed writes
do not mark an item complete. The agent must request `complete_assessment` as its
last safe output.

Older failed runs may already have added a rocket before they failed. Once the
updated workflow is on the default branch, retry one with:

```sh
gh workflow run issue-assessment.lock.yml \
  -f force=true \
  -f 'aw_context={"item_type":"issue","item_number":24}'
```

Replace `24` with the report number. Only a manual dispatch can bypass a marker.
Keep automatic failure reporting enabled so transport failures remain visible.
