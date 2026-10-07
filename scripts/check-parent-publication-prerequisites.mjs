import { assertIssuedIntegratedContract } from './integrated-publication-contract.mjs';
import { assertIssuedPublicationBundle, revalidatePublicationBundle } from './integrated-publication-assets.mjs';
import { assertParentEvidenceRegistry } from './integrated-publication-evidence.mjs';
import { revalidateObservedPublicationPlan } from './plan-integrated-publication.mjs';

/** Parent-owned common prerequisite join. No CLI, caller JSON, permission
 * token, native process creation or public dispatch. The real parent actor
 * must independently establish action-time direct authority and native
 * custody; this integrity result cannot satisfy either condition.
 */
export function checkParentPublicationPrerequisites(contract, bundle, registry, plan, parentSession) {
  assertIssuedIntegratedContract(contract);
  assertIssuedPublicationBundle(bundle);
  revalidatePublicationBundle(bundle);
  assertParentEvidenceRegistry(contract, bundle, registry, parentSession);
  const evidence = registry.assertThroughStage('adopt');
  const destinations = revalidateObservedPublicationPlan(contract, bundle, plan);
  return Object.freeze({ candidate_identity: bundle.identity,
    registered_originals: evidence.registered_originals,
    verified_stages: evidence.stages,
    public_plan_integrity_verified: destinations.plan_integrity_verified,
    missing_assets: plan.missing_assets,
    planned_operations: plan.operations.length,
    action_time_authority_verified: false,
    native_custody_verified: false,
    publication_admitted: false });
}
