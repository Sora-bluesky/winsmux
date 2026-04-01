# Security Rules

Security checklist to always verify when writing code.

## Secrets Management

### Never Do

- Hardcode API keys or passwords
- Log sensitive information
- Commit `.env` files

### Required

```python
# Good: Get from environment variables
import os
API_KEY = os.environ["API_KEY"]

# Good: With existence check
API_KEY = os.environ.get("API_KEY")
if not API_KEY:
    raise ValueError("API_KEY environment variable is required")
```

## Input Validation

Always validate external input:

```python
from pydantic import BaseModel, EmailStr, Field

class UserInput(BaseModel):
    email: EmailStr
    age: int = Field(ge=0, le=150)
    name: str = Field(min_length=1, max_length=100)
```

## SQL Injection Prevention

```python
# Bad: String concatenation
cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")

# Good: Parameterized query
cursor.execute("SELECT * FROM users WHERE id = ?", (user_id,))
```

## XSS Prevention

- Escape user input before embedding in HTML
- Enable template engine auto-escaping

## Error Messages

```python
# Bad: Too detailed (gives attackers information)
raise Exception(f"Database connection failed: {connection_string}")

# Good: Minimal information
raise Exception("Database connection failed")
# Details go to logs (logs are private)
logger.error(f"Database connection failed: {connection_string}")
```

## Dependencies

- Regular vulnerability checks: `pip-audit`, `safety`
- Remove unused dependencies
- Pin versions (`==` over `>=`)

## Code Review Checklist

- [ ] No hardcoded secrets
- [ ] External input is validated
- [ ] SQL queries are parameterized
- [ ] Error messages are not too detailed
- [ ] Logs don't contain sensitive information

## Git Operations Safety

git rm --cached is a prohibited operation.
Locally it appears to only remove files from the index,
but after committing, it propagates as physical deletion
when others pull/merge from the remote.

Prohibited commands:

- git rm --cached (single files or directories)
- git rm -r --cached (recursive untrack)

When managing files that should not be tracked via .gitignore,
the principle is to never commit them in the first place.
Simply adding an already-committed file to .gitignore does not
remove it from tracking, which tempts the use of git rm --cached,
but it is prohibited for the reasons stated above.

Alternative: When you need to remove already-committed files from tracking,
consult the human (project owner) and determine the approach
after confirming the impact scope.

## Line Ending Management

Line ending normalization is managed by `.gitattributes` only.
Do not set `core.autocrlf=true` in this repository.

When restoring files from old commits (`git checkout <commit> -- <path>`),
always run `git add --renormalize .` afterward to re-apply `.gitattributes` rules.
Otherwise, phantom diffs will appear in `git status` due to EOL mismatch.
