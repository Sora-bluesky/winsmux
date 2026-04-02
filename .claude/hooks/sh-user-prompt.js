const fs = require('fs');
const path = require('path');

const SEVERITY_ORDER = ['low', 'medium', 'high', 'critical'];
const CHANNEL_TAG_RE = /<channel\s+source="(telegram|discord)">/i;
const PATTERNS_PATH = path.join(__dirname, '..', 'patterns', 'injection-patterns.json');

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

function loadPatterns(filePath) {
  if (!fs.existsSync(filePath)) {
    return [];
  }

  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function toSeverityIndex(severity) {
  const index = SEVERITY_ORDER.indexOf(String(severity).toLowerCase());
  return index === -1 ? SEVERITY_ORDER.indexOf('medium') : index;
}

function boostSeverity(severity) {
  const index = toSeverityIndex(severity);
  return SEVERITY_ORDER[Math.min(index + 1, SEVERITY_ORDER.length - 1)];
}

function compilePattern(pattern) {
  if (typeof pattern !== 'string' || pattern.length === 0) {
    return null;
  }

  const slashPattern = pattern.match(/^\/(.+)\/([a-z]*)$/i);
  if (slashPattern) {
    try {
      return new RegExp(slashPattern[1], slashPattern[2]);
    } catch {
      return null;
    }
  }

  try {
    return new RegExp(pattern, 'i');
  } catch {
    return null;
  }
}

async function main() {
  const rawInput = await readStdin();
  const parsedInput = rawInput ? JSON.parse(rawInput) : {};
  const prompt = typeof parsedInput.prompt === 'string' ? parsedInput.prompt : '';
  const normalizedPrompt = prompt.normalize('NFKC');
  const isChannel = CHANNEL_TAG_RE.test(prompt);
  const patterns = loadPatterns(PATTERNS_PATH);

  let matchedDecision = null;

  for (const entry of patterns) {
    const regex = compilePattern(entry.pattern);
    if (!regex || !regex.test(normalizedPrompt)) {
      continue;
    }

    const baseSeverity = String(entry.severity || 'medium').toLowerCase();
    const severity = isChannel ? boostSeverity(baseSeverity) : SEVERITY_ORDER[toSeverityIndex(baseSeverity)];

    if (!matchedDecision || toSeverityIndex(severity) > toSeverityIndex(matchedDecision.severity)) {
      matchedDecision = {
        pattern: entry.pattern,
        severity,
      };
    }
  }

  if (matchedDecision && toSeverityIndex(matchedDecision.severity) >= toSeverityIndex('high')) {
    process.stdout.write(
      JSON.stringify({
        result: 'deny',
        reason: 'Injection pattern detected',
        pattern: matchedDecision.pattern,
        severity: matchedDecision.severity,
      })
    );
    process.exit(2);
  }
}

main().catch(() => {
  process.exit(0);
});
