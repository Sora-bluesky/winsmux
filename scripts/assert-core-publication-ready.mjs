// TASK885 owns the integrated-candidate gate described in EXECUTION-ACCEPTANCE.
// Preparation receipts, caller-supplied flags and dispatch inputs grant no release authority.
export function assertCorePublicationReady() {
  throw new Error('Core publication refused: the required TASK885 integrated-candidate gate is not connected.');
}
if (process.argv[1]?.endsWith('/assert-core-publication-ready.mjs')
  || process.argv[1]?.endsWith('\\assert-core-publication-ready.mjs')) {
  try { assertCorePublicationReady(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
