# adult-hockey-agent Conventions

Relocated verbatim from CLAUDE.md on 2026-07-20 (CPT slim-pointer migration). Naming, code style, and testing rules.

## Naming Convention

**CRITICAL**: Always use the full three-word name "adult-hockey-agent" in all contexts. Never use shortened versions.

### Internal References (code, configs, infrastructure)
- **Repository name**: `adult-hockey-agent`
- **Package name**: `adult-hockey-agent` (package.json)
- **PM2 app name**: `adult-hockey-agent`
- **File paths**: `/path/to/adult-hockey-agent/`
- **Git references**: `adult-hockey-agent`
- **Droplet hostname**: `adult-hockey-agent`
- **Firewall name**: `adult-hockey-agent-firewall`
- **Nginx upstream**: `adult_hockey_agent` (underscores for variable names)
- **Backup scripts**: `backup-adult-hockey-agent.sh`

### System Usernames (no hyphens allowed)
- **SSH/system user**: `adulthockey` (one word, no hyphens)
- **File ownership**: `adulthockey:adulthockey`
- **Home directory**: `/home/adulthockey`

### External/Marketing References
- **Public name**: "Adult Hockey Agent" (title case, spaces)
- **Documentation titles**: "Adult Hockey Agent"
- **README headers**: "# Adult Hockey Agent"

### ❌ NEVER Use These
- ~~`hockey-agent`~~ (missing "adult-")
- ~~`hockey`~~ (too generic, ambiguous)
- ~~`aha`~~ or ~~`AHA`~~ (unclear acronym)
- ~~`user: hockey`~~ (should be `adulthockey`)

### Why This Matters
1. **Clarity**: "hockey-agent" is ambiguous (youth? league? standings?)
2. **Searchability**: Full name ensures unique, unambiguous search results
3. **Professionalism**: Consistent naming across codebase, docs, and infrastructure
4. **Portability**: If project scope expands (youth hockey, league stats), naming remains clear

**Rule of thumb**: When in doubt, use the full three-word name `adult-hockey-agent` with hyphens (or `adulthockey` for usernames where hyphens aren't allowed).

## Code Style

- No semicolons (Prettier handles it)
- Single quotes
- 2-space indentation
- Explicit return types on all exported functions
- Comments only for: non-obvious business logic, DASH-specific quirks, or workarounds

## Testing

- Vitest for all tests
- Test against saved HTML fixtures, not live DASH site
- Parser tests: verify extraction against real page snapshots
- Evaluator tests: cover all alert rules including edge cases
- State tests: verify suppression logic and transitions
- No mocking Playwright in unit tests — use fixture files instead
