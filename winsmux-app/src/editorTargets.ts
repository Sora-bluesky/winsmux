export interface EditorPathCandidate {
  path: string;
  worktree: string;
}

export function getEditorFileKey(path: string, worktree = "") {
  return `${worktree.trim() || "."}::${path}`;
}

export function getSourceChangeKey(change: EditorPathCandidate) {
  return getEditorFileKey(change.path, change.worktree);
}

export function pickEditorPathCandidate<T extends EditorPathCandidate>(
  candidates: T[],
  path: string,
  requestedWorktree = "",
  selectedKey = "",
) {
  const pathMatches = candidates.filter((entry) => entry.path === path);
  if (pathMatches.length === 0) {
    return null;
  }

  if (requestedWorktree) {
    const exact = pathMatches.find((entry) => entry.worktree === requestedWorktree);
    if (exact) {
      return exact;
    }
  }

  if (pathMatches.length === 1) {
    return pathMatches[0];
  }

  if (selectedKey) {
    const selected = pathMatches.find((entry) => getSourceChangeKey(entry) === selectedKey);
    if (selected) {
      return selected;
    }
  }

  return null;
}

export function pickSourceChangeKeyCandidate<T extends EditorPathCandidate>(
  candidateGroups: T[][],
  key: string,
) {
  const seen = new Set<string>();

  for (const candidates of candidateGroups) {
    for (const candidate of candidates) {
      const candidateKey = getSourceChangeKey(candidate);
      if (seen.has(candidateKey)) {
        continue;
      }
      seen.add(candidateKey);
      if (candidateKey === key) {
        return candidate;
      }
    }
  }

  return null;
}
