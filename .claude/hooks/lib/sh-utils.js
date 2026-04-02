const crypto = require("crypto");
const fs = require("fs");

function deny(reason) {
  process.stdout.write(`${JSON.stringify({ decision: "deny", reason })}\n`);
  process.exit(2);
}

function allow() {
  process.exit(0);
}

function readStdin() {
  const raw = fs.readFileSync(0, "utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function sha256(data) {
  return crypto.createHash("sha256").update(String(data)).digest("hex");
}

module.exports = {
  deny,
  allow,
  readStdin,
  sha256,
};
