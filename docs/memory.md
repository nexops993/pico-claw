# Memory

Pico Claw memory is an in-process store backed by one JSONL file per category under `data/memory/`:

- `semantic.jsonl`
- `episodic.jsonl`
- `procedural.jsonl`
- `error.jsonl`
- `preference.jsonl`

Entries contain numeric `id`, string `content`, and numeric `importance`; category comes from file loaded. Files are loaded at startup. Public memory APIs can add entries and rewrite corresponding category file. Current chat/learning flow retrieves memory but does not automatically create memory entries.

This JSONL store is separate from the hand-curated owner file `MEMORY.md`, which is loaded as durable owner context with a configurable size budget. See [SOUL and MEMORY](soul-memory.md). Nothing writes to `MEMORY.md` automatically.

## Retrieval

Query is tokenized, punctuation normalized, and Indonesian stopwords ignored. Case-insensitive whole-word matches increase relevance; substring/full-query matches add bonuses. Results sort by descending score. Conversation calls bounded retrieval with maximum 10 entries and includes them as facts, not behavior-changing instructions.

This is lexical relevance, not embeddings or semantic/vector search.

## Ownership

Store owns entry content. Retrieval returns allocated arrays containing borrowed entry fields. Callers free result arrays through `freeSearchResults`; store frees content at shutdown. Loaded entries are copied into store ownership.

## Git and privacy

Runtime JSONL under `data/` is ignored. `data/.gitkeep` preserves directory root only. Do not commit memory: it may contain personal or sensitive facts. JSONL remains plaintext locally; protect filesystem permissions and backups. Missing files are valid empty stores; malformed or inaccessible memory files can stop initialization depending on load error.
