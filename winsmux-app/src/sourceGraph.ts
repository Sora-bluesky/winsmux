export const sourceGraphMaxLanes = 6;

export type SourceGraphLaneKind =
  | "node"
  | "vertical"
  | "diagonal-left"
  | "diagonal-right"
  | "horizontal"
  | "connector"
  | "empty";

export function isSourceGraphColumnPlaceholder(symbol: string) {
  return symbol.trim().length === 0;
}

export function normalizeSourceGraphTokens(symbols: string, maxLanes = sourceGraphMaxLanes) {
  const boundedMaxLanes = Math.max(0, maxLanes);
  const graphSymbols = symbols.trimEnd();
  if (!graphSymbols) {
    return ["*"];
  }
  const tokens = Array.from(graphSymbols).slice(0, boundedMaxLanes);
  return tokens.length > 0 ? tokens : ["*"];
}

export function getSourceGraphLaneKind(symbol: string): SourceGraphLaneKind {
  if (symbol === "*" || symbol === "o") {
    return "node";
  }
  if (symbol === "|") {
    return "vertical";
  }
  if (symbol === "/") {
    return "diagonal-left";
  }
  if (symbol === "\\") {
    return "diagonal-right";
  }
  if (symbol === "_" || symbol === "-") {
    return "horizontal";
  }
  return isSourceGraphColumnPlaceholder(symbol) ? "empty" : "connector";
}
