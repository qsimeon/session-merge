---
name: session-merge
description: |
  **Claude Code Session Merger**: Merge two or more Claude Code conversation sessions into a single unified session. Use this skill whenever the user mentions merging sessions, combining sessions, session splitting problems, reuniting split sessions, consolidating conversation history, or wants to combine work from separate Claude Code sessions into one. Also trigger when the user complains about sessions being split unexpectedly, losing context across sessions, or wanting a "mega session" from multiple conversations. This skill works with the JSONL session files stored in ~/.claude/projects/.
---

# Session Merge Skill

This skill helps users merge multiple Claude Code sessions into a single unified session. It's useful when:

- A session got unexpectedly split (e.g., after plan mode transitions, cd operations, or exit/resume cycles)
- The user worked on related features in separate sessions and wants to combine them
- Context was lost across sessions and the user wants everything in one place

## How Claude Code Sessions Work

Sessions are stored as JSONL files in `~/.claude/projects/<project-hash>/`. Each project directory corresponds to a working directory path (slashes become hyphens). Inside each project directory:

- `<session-uuid>.jsonl` — The main conversation history (one JSON object per line)
- `<session-uuid>/subagents/` — Subagent conversation threads
- `sessions-index.json` — Metadata index for all sessions in that project

Each JSONL entry has key fields: `timestamp`, `uuid`, `parentUuid`, `sessionId`, `type` (user/assistant/tool_result), `message`, `cwd`, and optionally `slug` (the human-readable session name).

## The Merge Script

This skill includes a bash script at `scripts/merge_sessions.sh` that handles the mechanics. It supports:

- `--list` — Show all sessions across all projects with their IDs, names, sizes, timestamps, and first message
- `--list-project <path>` — Filter to sessions for a specific project
- `--find-splits` — Detect and display all "split" session groups (sessions sharing the same slug/name)
- `--merge-splits` — Automatically merge all split session groups back together (with confirmation prompt)
- `--name <name>` — Set a name/slug for the merged session
- `--delete-sources` — Remove the original sessions after merging
- `--dry-run` — Preview the merge without making changes

## Workflow

When the user invokes this skill, walk them through these steps:

### Quick Fix: Auto-Merge All Splits

If the user just wants to fix all split sessions at once, use the quick path:

```bash
bash <skill-path>/scripts/merge_sessions.sh --find-splits
```

This shows all session groups that share the same name (i.e., sessions that were split). If the user wants to merge them all:

```bash
bash <skill-path>/scripts/merge_sessions.sh --merge-splits
```

This will prompt for confirmation, then automatically merge each group back into a single session using the original name.

### Step 1: Discover Sessions

Run the list command to show all available sessions:

```bash
bash <skill-path>/scripts/merge_sessions.sh --list
```

Present the results to the user in a readable format. Highlight the current session if identifiable. Help the user identify which sessions they want to merge — they might know them by name, by timeframe, by the first message, or by size.

If the list is very long, offer to filter by project:

```bash
bash <skill-path>/scripts/merge_sessions.sh --list-project /path/to/project
```

### Step 2: Confirm Merge Parameters

Ask the user:

1. **Which sessions to merge** — They should provide 2 or more session IDs (the UUIDs). Help them identify the right ones from the list.
2. **What to name the merged session** — Suggest combining the existing names or letting them pick a new one.
3. **Whether to delete the source sessions** — Explain that deleting is optional and can be done later. Recommend keeping sources initially as a safety measure, since the merge is not easily reversible.

### Step 3: Dry Run

Always do a dry run first so the user can verify:

```bash
bash <skill-path>/scripts/merge_sessions.sh --dry-run --name "chosen-name" <id1> <id2> [id3...]
```

Show the user the merge plan: source sessions with their sizes, the target project, and the new session ID.

### Step 4: Execute the Merge

Once the user confirms, run the actual merge:

```bash
bash <skill-path>/scripts/merge_sessions.sh --name "chosen-name" <id1> <id2> [id3...]
```

If they want to delete sources:

```bash
bash <skill-path>/scripts/merge_sessions.sh --name "chosen-name" --delete-sources <id1> <id2> [id3...]
```

### Step 5: Verify

After merging, confirm success by:

1. Checking the merged file exists and has the expected size
2. Running `--list` again to show the new session appears
3. Telling the user how to resume the merged session: `claude --resume "chosen-name"`

## What the Merge Does Technically

The merge process:

1. **Collects** all JSONL entries from every source session
2. **Sorts** them chronologically by the `timestamp` field — this interleaves the conversations in the order they actually happened
3. **Rewrites** the `sessionId` field on every entry to the new merged session's UUID, so Claude Code treats them as one continuous session
4. **Updates** the `slug` field (if a name was provided) so the session is findable by name
5. **Copies** all subagent files from source sessions into the merged session's subagent directory
6. **Updates** the `sessions-index.json` metadata file with the new session entry

The `parentUuid` threading within each original session is preserved — messages still reference their correct parent. The only change is that all entries now share a single `sessionId`.

## Important Caveats

- **Cross-project merges**: If sessions are from different projects (different working directories), the merged session is placed in the first session's project directory. This is fine for resuming, but the working directory context (`cwd`) in each message still reflects the original directory at the time.
- **No semantic deduplication**: This is a chronological merge, not a smart content-aware merge. If both sessions have overlapping content (e.g., the same file was read in both), both entries appear in the merged history.
- **Context window**: Merging doesn't change Claude's context window behavior. When you resume the merged session, Claude still has its normal context limits. But the full history is available for reference and the session picker will show it as one session.
- **Backup recommendation**: The `--dry-run` flag exists for a reason. Encourage users to verify before committing, and suggest keeping source sessions until they've confirmed the merge looks right.
