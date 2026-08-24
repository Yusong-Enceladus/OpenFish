/** Verify the production JS bundles do not escape back into workspace TS. */
const codex = await import('../packages/subagent/subagent-codex/lib/index.js')
const harness = await import('../packages/harness/harness-acp/lib/index.js')

if (typeof codex.CodexAppServerWire !== 'function') {
  throw new Error('built subagent-codex bundle does not export CodexAppServerWire')
}
if (harness.name !== 'harness-acp' || typeof harness.apply !== 'function') {
  throw new Error('built Harness Driver bundle is incomplete')
}
console.log('OpenFish built Harness runtime import passed')
