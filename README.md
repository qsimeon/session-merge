# session-merge

A [Claude Code](https://claude.ai/code) skill for merging split or related sessions into one continuous conversation history.

**[Read the docs →](https://qsimeon.github.io/session-merge)**

## The Problem

Claude Code sessions split unexpectedly — after `cd` operations, exit/resume cycles, or version updates. You end up with multiple sessions sharing the same name but containing fragments of what was supposed to be one conversation. There's no built-in way to recombine them.

## Quick Start

```bash
# Install
cp -r session-merge ~/.claude/skills/session-merge

# Find all split sessions
bash ~/.claude/skills/session-merge/scripts/merge_sessions.sh --find-splits

# Auto-merge all splits
bash ~/.claude/skills/session-merge/scripts/merge_sessions.sh --merge-splits

# Or merge specific sessions
bash merge_sessions.sh --name "my-session" <session-id-1> <session-id-2>
```

## How It Works

The script operates on the JSONL session files in `~/.claude/projects/`:

1. **Collects** all entries from source sessions
2. **Sorts** them chronologically by timestamp
3. **Rewrites** `sessionId` fields to a new merged UUID
4. **Copies** subagent files and updates the session index

## Flags

| Flag | Description |
|------|-------------|
| `--list` | List all sessions across all projects |
| `--find-splits` | Detect duplicate-named session groups |
| `--merge-splits` | Auto-merge all split groups (with confirmation) |
| `--name <name>` | Name for the merged session |
| `--delete-sources` | Remove originals after merge |
| `--dry-run` | Preview without making changes |

## License

MIT
