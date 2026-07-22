# Contributing

Thank you for contributing.

## Development Setup

1. Install prerequisites listed in README.md.
2. Sign in to Azure CLI with the correct tenant and subscription.
3. Run:

```powershell
.\scripts\check-prereqs.ps1
```

## Coding Guidelines

- Keep changes scoped and minimal.
- Prefer idempotent scripts.
- Use descriptive logs for every mutating operation.
- Preserve backward compatibility for existing script parameters when possible.
- Add or update documentation when behavior changes.

## Validation Checklist

Before submitting changes:

1. Parse-check all PowerShell scripts.
2. Run `dotnet build -c Release` in weather-api.
3. Run relevant script flows in `-WhatIfOnly` mode when available.
4. Update scripts/README.md and root README.md for any new parameters/steps.

## Pull Request Notes

Include:

- Problem statement
- Approach and key changes
- Validation evidence (commands run and results)
- Any known limitations or follow-up work
