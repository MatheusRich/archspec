'use strict';

function itemFor(context) {
  const routed = JSON.parse(context.payload.inputs?.aw_context || '{}');
  const type = context.payload.issue ? 'issue' : context.payload.discussion ? 'discussion' : routed.item_type;
  const number = Number(context.payload.issue?.number || context.payload.discussion?.number || routed.item_number);
  if (!['issue', 'discussion'].includes(type) || !Number.isSafeInteger(number) || number <= 0) {
    throw new Error('An issue or discussion number is required');
  }
  return { type, number };
}

async function reactionsFor(github, context, item) {
  if (item.type === 'issue') {
    const reactions = await github.paginate(github.rest.reactions.listForIssue,
      { ...context.repo, issue_number: item.number, per_page: 100 });
    return { reactions };
  }
  const result = await github.graphql(
    `query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        discussion(number: $number) {
          id
          reactions(first: 100, content: ROCKET) { nodes { content user { login } } }
        }
      }
    }`, { ...context.repo, number: item.number });
  const discussion = result.repository.discussion;
  if (!discussion) throw new Error(`Discussion #${item.number} was not found`);
  return { discussionId: discussion.id, reactions: discussion.reactions.nodes };
}

async function assessmentNeeded(github, context) {
  const item = itemFor(context);
  const force = context.eventName === 'workflow_dispatch' &&
    [true, 'true'].includes(context.payload.inputs?.force);
  if (force) return true;
  const { reactions } = await reactionsFor(github, context, item);
  const trusted = new Set([context.repo.owner, 'github-actions[bot]']);
  return !reactions.some(reaction => reaction.content.toLowerCase() === 'rocket' && trusted.has(reaction.user?.login));
}

async function markAssessed(github, context, output, counts) {
  const allowed = new Set(['add_labels', 'add_comment', 'close_issue', 'noop', 'complete_assessment']);
  if (Number(counts.failed) !== 0 || !(Number(counts.succeeded) > 0) ||
      (output.errors || []).length || !Array.isArray(output.items) ||
      output.items.some(item => !allowed.has(item.type)) ||
      !output.items.some(item => allowed.has(item.type) && item.type !== 'complete_assessment')) {
    throw new Error('Assessment did not complete successfully; leaving it retryable');
  }
  const item = itemFor(context);
  if (item.type === 'issue') {
    await github.rest.reactions.createForIssue({ ...context.repo, issue_number: item.number, content: 'rocket' });
  } else {
    const { discussionId } = await reactionsFor(github, context, item);
    await github.graphql(
      `mutation($subjectId: ID!) {
        addReaction(input: {subjectId: $subjectId, content: ROCKET}) { reaction { content } }
      }`, { subjectId: discussionId });
  }
}

module.exports = { itemFor, assessmentNeeded, markAssessed };
