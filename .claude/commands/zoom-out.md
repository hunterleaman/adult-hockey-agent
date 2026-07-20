## Subagent delegation reminder
Before any Read/Grep/Bash in this command's main session, ask: "Can a subagent return a 3-line summary?" If yes, delegate via the `Agent` tool with subagent_type `Explore` for codebase queries or `general-purpose` for multi-step research. Reserve the main session's context for orchestration and operator-facing decisions only.

---

I don't know this area of code well. Go up a layer of abstraction. Give me a map of all the relevant modules and callers, using the project's domain glossary vocabulary.
