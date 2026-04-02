// sh-orchestra-gate.js — PreToolUse hook
// Prevents Commander from writing code or bypassing psmux-bridge
const fs = require('fs');

try {
  const input = fs.readFileSync(0, 'utf8');
  const event = JSON.parse(input);
  const toolName = event.tool_name || '';
  const toolInput = event.tool_input || {};

  // Rule 1: Commander cannot write/edit code files
  if (toolName === 'Write' || toolName === 'Edit') {
    const filePath = toolInput.file_path || toolInput.file || '';
    if (/\.(ps1|js|rs|ts|py)$/i.test(filePath)) {
      deny('Commander cannot write code files. Delegate to Builder via psmux-bridge send.');
    }
  }

  // Rule 2: No direct psmux send-keys (use psmux-bridge send)
  if (toolName === 'Bash') {
    const cmd = toolInput.command || '';
    if (/psmux\s+send-keys/.test(cmd) && !/psmux-bridge/.test(cmd)) {
      deny('Use psmux-bridge send instead of direct psmux send-keys.');
    }
  }

  // Rule 3: No plaintext secrets in commands
  if (toolName === 'Bash') {
    const cmd = toolInput.command || '';
    if (/(gho_|ghp_|sk-|GITHUB_TOKEN=|GH_TOKEN=|API_KEY=)/i.test(cmd)) {
      deny('Use psmux-bridge vault instead of plaintext secrets.');
    }
  }

  // Rule 4: No direct codex exec (use orchestra-start)
  if (toolName === 'Bash') {
    const cmd = toolInput.command || '';
    if (/codex\s+(exec|e)\s/.test(cmd) && !/psmux\s+send-keys/.test(cmd)) {
      deny('Use orchestra-start or psmux send-keys to dispatch Codex, not direct codex exec.');
    }
  }

  // Rule 5: Block shallow git clones (they break worktree creation)
  if (toolName === 'Bash') {
    const cmd = toolInput.command || '';
    if (/git\s+clone\s+.*--depth/.test(cmd)) {
      deny('Shallow clones break git worktree. Use full clone (remove --depth).');
    }
  }

  // Allow
  process.exit(0);
} catch (e) {
  // Parse error — fail-close
  deny('Hook parse error: ' + e.message);
}

function deny(reason) {
  process.stderr.write(JSON.stringify({
    hookSpecificOutput: { permissionDecision: 'deny' },
    systemMessage: reason,
  }));
  process.exit(2);
}
