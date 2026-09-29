// Reported cleanup and a captured projection are two separate observations.
// Later flags never retroactively turn an earlier running result into exited.
// This is not proof that native worker HANDLEs are signaled.
pub fn projected_cleanup_matches(response: &serde_json::Value, cleanup_flags: bool) -> bool {
    cleanup_flags
        && response["accepted"] == true
        && response["result"]["data"]["run"]["process"] == "exited"
        && response["result"]["data"]["run"]["evidence"] == "process_exit"
}
