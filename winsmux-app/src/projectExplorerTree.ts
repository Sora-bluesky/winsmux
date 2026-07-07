export interface ProjectExplorerEntryLike {
  path: string;
  kind: "directory" | "file";
  has_children?: boolean;
  ignored?: boolean;
}

export interface ProjectExplorerTreeNode {
  label: string;
  path: string;
  kind: "directory" | "file";
  hasChildren?: boolean;
  ignored?: boolean;
  children: Map<string, ProjectExplorerTreeNode>;
}

export function compareProjectExplorerNodes(left: ProjectExplorerTreeNode, right: ProjectExplorerTreeNode) {
  const leftIsFile = left.kind === "file";
  const rightIsFile = right.kind === "file";
  if (leftIsFile !== rightIsFile) {
    return leftIsFile ? 1 : -1;
  }
  return left.label.localeCompare(right.label, undefined, { sensitivity: "base" });
}

export function getProjectExplorerChildKey(label: string) {
  return label.toLocaleLowerCase();
}

export function createProjectExplorerTreeNode(
  label: string,
  path: string,
  kind: "directory" | "file",
  hasChildren?: boolean,
  ignored?: boolean,
): ProjectExplorerTreeNode {
  return {
    label,
    path,
    kind,
    hasChildren,
    ignored,
    children: new Map<string, ProjectExplorerTreeNode>(),
  };
}

export function buildProjectExplorerTree(entries: ProjectExplorerEntryLike[]) {
  const rootChildren = new Map<string, ProjectExplorerTreeNode>();

  for (const entry of entries) {
    const segments = entry.path.split("/").filter(Boolean);
    let currentChildren = rootChildren;
    let currentPath = "";

    segments.forEach((segment, index) => {
      currentPath = currentPath ? `${currentPath}/${segment}` : segment;
      const isFinalSegment = index === segments.length - 1;
      const nodeKind = isFinalSegment ? entry.kind : "directory";
      const childKey = getProjectExplorerChildKey(segment);
      let node = currentChildren.get(childKey);

      if (!node) {
        node = createProjectExplorerTreeNode(
          segment,
          currentPath,
          nodeKind,
          isFinalSegment ? entry.has_children : true,
          isFinalSegment ? entry.ignored : false,
        );
        currentChildren.set(childKey, node);
      } else if (nodeKind === "directory") {
        node.kind = "directory";
      }
      if (node.kind === "directory") {
        node.hasChildren = node.hasChildren || !isFinalSegment || entry.has_children;
      }
      if (isFinalSegment && entry.ignored) {
        node.ignored = true;
      }

      currentChildren = node.children;
    });
  }

  return rootChildren;
}
