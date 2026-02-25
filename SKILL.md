---
name: session-merge
author: Quilee Simeon <qsimeon@mit.edu>
url: https://qsimeon.github.io/session-merge
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

When the user invokes this skill, you MUST follow these steps in order. Do NOT skip Step 1.

### Step 1: Discover Sessions (REQUIRED FIRST STEP)

**ALWAYS start here.** Run the list command to show all available sessions:

```bash
bash <skill-path>/scripts/merge_sessions.sh --list
```

Present the results to the user in a readable format. Highlight the current session if identifiable. Help the user identify which sessions they want to merge — they might know them by name, by timeframe, by the first message, or by size.

If the list is very long, offer to filter by project:

```bash
bash <skill-path>/scripts/merge_sessions.sh --list-project /path/to/project
```

**Do NOT run `--find-splits` or `--merge-splits` before running `--list` first.** The `--list` command uses only basic bash and always works. The split-detection commands require bash 4+ (associative arrays) and may fail on macOS default bash.

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
3. **IMPORTANT**: Tell the user to resume using the **session ID** (UUID), not the name. The name may not appear in the picker immediately. Example: `cd ~ && claude --resume <session-uuid>`. Once inside the session, the name will be set correctly and they can rename if needed.

### Optional: Auto-Merge All Splits

Only use this AFTER you've confirmed `--list` works successfully. If the user wants to fix all split sessions at once (sessions sharing the same name), you can use:

```bash
bash <skill-path>/scripts/merge_sessions.sh --find-splits
```

This shows all session groups that share the same name. If the user wants to merge them all:

```bash
bash <skill-path>/scripts/merge_sessions.sh --merge-splits
```

Note: These commands require bash 4+ (for associative arrays). On macOS, the script will attempt to find Homebrew's bash automatically, but if it fails, fall back to the manual workflow (Steps 1–5 above).

## What the Merge Does Technically

The merge process:

1. **Collects** all JSONL entries from every source session
2. **Finds the main conversation trunk** of each session (the longest parentUuid chain from leaf to root)
3. **Sorts sessions** chronologically by their earliest timestamp
4. **Stitches trunks together**: sets the root of session N+1's parentUuid to the leaf of session N, creating one continuous chain
5. **Sorts all entries** by timestamp and writes them with the new merged `sessionId`
6. **Updates** the `slug` field (if a name was provided) so the session is findable by name
7. **Copies** all subagent files from source sessions into the merged session's subagent directory
8. **Creates/updates** the `sessions-index.json` metadata file with the new session entry

The tree stitching ensures Claude Code can walk one continuous parentUuid chain when resuming the merged session, rather than seeing disconnected conversation fragments.

## Where Merged Sessions Live

**All merged sessions are placed in the home directory project** (`~/.claude/projects/-Users-<username>/`). This means merged sessions are always resumable from `~` with `cd ~ && claude --resume "session-name"`, regardless of which project directories the source sessions originally came from.

## Important Caveats

- **Resume from home**: Merged sessions always live in the `~` project. Resume with `cd ~ && claude --resume "name"`.
- **No semantic deduplication**: This is a chronological merge, not a smart content-aware merge. If both sessions have overlapping content (e.g., the same file was read in both), both entries appear in the merged history.
- **Context window**: Merging doesn't change Claude's context window behavior. When you resume the merged session, Claude still has its normal context limits. But the full history is available for reference and the session picker will show it as one session.
- **Backup recommendation**: The `--dry-run` flag exists for a reason. Encourage users to verify before committing, and suggest keeping source sessions until they've confirmed the merge looks right.
