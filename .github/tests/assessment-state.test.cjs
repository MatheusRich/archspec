'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { itemFor, assessmentNeeded, markAssessed } = require('../scripts/assessment-state.cjs');

const issueContext = { repo: { owner: 'crmne', repo: 'archspec' }, eventName: 'issues', payload: { issue: { number: 24 } } };
function client(reactions = []) {
  const writes = [];
  return {
    writes,
    rest: { reactions: { listForIssue: () => {}, createForIssue: async data => writes.push(data) } },
    paginate: async () => reactions,
    graphql: async (query, data) => {
      if (query.includes('mutation')) { writes.push(data); return {}; }
      return { repository: { discussion: { id: 'discussion-9', reactions: { nodes: reactions } } } };
    },
  };
}

test('an unassessed report is not marked before execution', async () => {
  const github = client();
  assert.equal(await assessmentNeeded(github, issueContext), true);
  assert.deepEqual(github.writes, []);
});
test('only trusted completion reactions prevent assessment', async () => {
  for (const login of ['crmne', 'github-actions[bot]', 'visitor']) {
    const github = client([{ content: 'rocket', user: { login } }]);
    assert.equal(await assessmentNeeded(github, issueContext), login === 'visitor');
    assert.deepEqual(github.writes, []);
  }
});
test('a manual retry can bypass legacy markers; issue payloads cannot', async () => {
  const github = client([{ content: 'rocket', user: { login: 'github-actions[bot]' } }]);
  const payload = { ...issueContext.payload, inputs: { force: 'true' } };
  assert.equal(await assessmentNeeded(github, { ...issueContext, payload }), false);
  assert.equal(await assessmentNeeded(github, { ...issueContext, eventName: 'workflow_dispatch', payload }), true);
});
test('failed, empty, incomplete, and partially applied assessments stay retryable', async () => {
  const cases = [
    [{ items: [] }, { failed: '0', succeeded: '0' }],
    [{ items: [{ type: 'complete_assessment' }] }, { failed: '0', succeeded: '1' }],
    [{ items: [{ type: 'add_labels' }] }, { failed: '1', succeeded: '1' }],
    [{ items: [{ type: 'report_incomplete' }] }, { failed: '0', succeeded: '1' }],
    [{ items: [{ type: 'noop' }], errors: ['failure'] }, { failed: '0', succeeded: '1' }],
    [{ items: [{ type: 'noop' }] }, {}],
  ];
  for (const [output, counts] of cases) {
    const github = client();
    await assert.rejects(markAssessed(github, issueContext, output, counts));
    assert.deepEqual(github.writes, []);
  }
});
test('successful label and no-op assessments mark the triggering issue', async () => {
  for (const type of ['add_labels', 'noop']) {
    const github = client();
    await markAssessed(github, issueContext,
      { items: [{ type }, { type: 'complete_assessment' }] }, { failed: '0', succeeded: '1' });
    assert.deepEqual(github.writes, [{ owner: 'crmne', repo: 'archspec', issue_number: 24, content: 'rocket' }]);
  }
});
test('discussion completion is routed from the triggering context', async () => {
  const context = { ...issueContext, payload: { discussion: { number: 9 } } };
  const github = client();
  await markAssessed(github, context, { items: [{ type: 'noop' }] }, { failed: '0', succeeded: '1' });
  assert.deepEqual(github.writes, [{ subjectId: 'discussion-9' }]);
});
test('manual routing rejects malformed or missing item numbers', () => {
  for (const item_number of [0, -1, '1; anything', 1.5, null]) {
    assert.throws(() => itemFor({ payload: { inputs: { aw_context: JSON.stringify({ item_type: 'issue', item_number }) } } }));
  }
  assert.deepEqual(itemFor({ payload: { inputs: { aw_context: '{"item_type":"issue","item_number":27}' } } }),
    { type: 'issue', number: 27 });
});
