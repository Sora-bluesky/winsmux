// sh-orchestra-gate.js — PreToolUse hook
// Prevents Commander from writing code or bypassing psmux-bridge
const { stdin } = require('process');

let input = '';
stdin.setEncoding('utf8');
stdin.on('data', chunk => input += chunk);
stdin.on('end', () => {
  try {
    const event = JSON.parse(input);
    const toolName = event.tool_name || '';
    const toolInput = event.tool_input || {};

    // Rule 1: Commander cannot write/edit code files
    if (toolName === 'Write' || toolName === 'Edit') {
      const filePath = toolInput.file_path || toolInput.file || '';
      if (/\.(ps1|js|rs|ts|py)$/i.test(filePath)) {
        deny('Commander cannot write code files. Delegate to Builder via psmux-bridge send.');
        return;
      }
    }

    // Rule 2: No direct psmux send-keys (use psmux-bridge send)
    if (toolName === 'Bash') {
      const cmd = toolInput.command || '';
      if (/psmux\s+send-keys/.test(cmd) && !/psmux-bridge/.test(cmd)) {
        deny('Use psmux-bridge send instead of direct psmux send-keys.');
        return;
      }
    }

    // Rule 3: No plaintext secrets in commands
    if (toolName === 'Bash') {
      const cmd = toolInput.command || '';
      if (/(gho_|ghp_|sk-|GITHUB_TOKEN=|GH_TOKEN=|API_KEY=)/i.test(cmd)) {
        deny('Use psmux-bridge vault instead of plaintext secrets.');
        return;
      }
    }

    // Rule 4: No direct codex exec (use orchestra-start)
    if (toolName === 'Bash') {
      const cmd = toolInput.command || '';
      if (/codex\s+(exec|e)\s/.test(cmd) && !/psmux\s+send-keys/.test(cmd)) {
        deny('Use orchestra-start or psmux send-keys to dispatch Codex, not direct codex exec.');
        return;
      }
    }

    // Rule 5: Block shallow git clones (they break worktree creation)
    if (toolName === 'Bash') {
      const cmd = toolInput.command || '';
      if (/git\s+clone\s+.*--depth/.test(cmd)) {
        deny('Shallow clones break git worktree. Use full clone (remove --depth).');
        return;
      }
    }

    // Allow
    process.exit(0);
  } catch (e) {
    // Parse error — fail-close
    deny('Hook parse error: ' + e.message);
  }
});

function deny(reason) {
  console.log(JSON.stringify({ result: 'deny', reason }));
  process.exit(2);
}
