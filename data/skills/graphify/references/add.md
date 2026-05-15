# graphify add: ingest a URL into the corpus

Set `$PYTHON` first:

```bash
PYTHON=$(bash ~/.claude/skills/graphify/scripts/graphify-env.sh)
```

## /graphify add <url>

Fetch a URL and add it to the corpus, then automatically run `--update` to merge it into the graph.

```bash
$PYTHON -c "
import sys
from graphify.ingest import ingest
from pathlib import Path

try:
    out = ingest('URL', Path('./raw'), author='AUTHOR', contributor='CONTRIBUTOR')
    print(f'Saved to {out}')
except ValueError as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
except RuntimeError as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
"
```

Replace `URL` with the actual URL, `AUTHOR` with the user's name if provided via `--author`, `CONTRIBUTOR` likewise via `--contributor`. If the command exits with an error, tell the user what went wrong. Do not silently continue.

After a successful save, automatically run the `--update` pipeline on `./raw` to merge the new file into the existing graph. See `references/incremental.md`.

## Supported URL types (auto-detected)

| Type | Handling |
|---|---|
| Twitter/X | Fetched via oEmbed, saved as `.md` with tweet text and author |
| arXiv | Abstract + metadata saved as `.md` |
| PDF | Downloaded as `.pdf` |
| Images (.png/.jpg/.webp) | Downloaded; Claude vision extracts on next run |
| Any webpage | Converted to markdown via html2text |
