export function isDirectWorkerPaneInputEnabled(value: unknown): boolean {
  return value === true;
}

export function shouldForwardWorkerPaneInput(
  source: "user" | "dispatch",
  enabled: unknown,
): boolean {
  if (source === "dispatch") {
    return true;
  }
  return isDirectWorkerPaneInputEnabled(enabled);
}
