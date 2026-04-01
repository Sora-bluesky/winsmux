# Testing Rules

## Principles (Language-Agnostic)

- **TDD when possible**: Write tests before implementation (Red-Green-Refactor)
- **AAA Pattern**: Arrange / Act / Assert
- **Naming**: `test_{subject}_{condition}_{expected_result}`
- **Coverage target**: 80%+ for source code

## Test Categories

1. **Happy path**: Normal input, expected output
2. **Boundary values**: Min, max, empty, zero
3. **Error cases**: Invalid input, error conditions
4. **Edge cases**: Null, empty string, special characters

## PowerShell Testing (Pester)

When Pester is available:

```powershell
# Run tests
Invoke-Pester -Verbose

# Run with coverage
Invoke-Pester -CodeCoverage ./scripts/*.ps1

# Test file naming: {Module}.Tests.ps1
# Test structure: Describe / Context / It
```

## Current Testing Approach

Until a formal test framework is adopted:

- **Git guard**: Pre-commit hooks catch secrets and sensitive data
- **Manual verification**: Review output before committing

## Mocking

- Isolate external dependencies (file I/O, network, CLI tools)
- Use `unittest.mock` (Python hooks) or Pester `Mock` (PowerShell)
- Test fixtures in dedicated `tests/` directory when available
