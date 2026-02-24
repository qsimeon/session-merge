#!/usr/bin/env bash
#
# merge_sessions.sh — Merge two or more Claude Code sessions into one
#
# Usage:
#   merge_sessions.sh [OPTIONS] <session-id-1> <session-id-2> [session-id-3 ...]
#
# Options:
#   --name <name>          Name/slug for the merged session (default: auto-generated)
#   --delete-sources       Delete source session files after successful merge
#   --dry-run              Show what would happen without making changes
#   --output-id <uuid>     Use a specific UUID for the merged session (default: auto-generated)
#   --list                 List all sessions across all projects, then exit
#   --list-project <path>  List sessions for a specific project path, then exit
#   --find-splits          Find and display all split session groups, then exit
#   --merge-splits         Automatically merge all split session groups (with confirmation)
#   --help                 Show this help message
#
# The script:
#   1. Locates all source session JSONL files across ~/.claude/projects/
#   2. Combines their entries sorted by timestamp
#   3. Rewrites sessionId fields to the new merged session ID
#   4. Copies subagent files from all sources
#   5. Updates sessions-index.json if it exists
#   6. Optionally deletes source sessions
#
# Requirements: bash 4+, jq, python3 (for UUID generation and JSON processing)

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
    head -27 "$0" | tail -25 | sed 's/^# \?//'
    exit 0
}

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}$1${NC}"
}

success() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Generate a UUID v4
generate_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Get timestamp from a JSONL line
get_timestamp() {
    echo "$1" | python3 -c "import sys, json; obj=json.loads(sys.stdin.read()); print(obj.get('timestamp', '1970-01-01T00:00:00.000Z'))"
}

# Find the project directory containing a session ID
find_session_project() {
    local session_id="$1"
    local found=""

    for project_dir in "$PROJECTS_DIR"/*/; do
        if [ -f "${project_dir}${session_id}.jsonl" ]; then
            found="$project_dir"
            break
        fi
    done

    echo "$found"
}

# List all sessions across all projects
list_sessions() {
    local filter_project="${1:-}"

    echo -e "${BOLD}Claude Code Sessions${NC}"
    echo "========================="
    echo ""

    local total=0

    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue

        local project_name
        project_name=$(basename "$project_dir")

        # If filtering by project, skip non-matching
        if [ -n "$filter_project" ]; then
            local encoded_path
            encoded_path=$(echo "$filter_project" | sed 's|/|-|g')
            if [ "$project_name" != "$encoded_path" ] && [ "$project_name" != "-${encoded_path}" ] && [ "$project_name" != "-${encoded_path}-" ]; then
                continue
            fi
        fi

        local session_count=0
        local session_lines=""

        for jsonl_file in "$project_dir"*.jsonl; do
            [ -f "$jsonl_file" ] || continue

            local session_id
            session_id=$(basename "$jsonl_file" .jsonl)

            # Skip if not a UUID-like pattern (could be other jsonl files)
            if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
                continue
            fi

            # Get metadata from the file
            local slug=""
            local first_ts=""
            local last_ts=""
            local line_count=0
            local first_user_msg=""

            line_count=$(wc -l < "$jsonl_file" | tr -d ' ')

            # Get slug from last occurrence in file
            slug=$(grep -o '"slug":"[^"]*"' "$jsonl_file" 2>/dev/null | tail -1 | sed 's/"slug":"//;s/"//' || echo "")

            # Get first timestamp
            first_ts=$(head -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")

            # Get last timestamp
            last_ts=$(tail -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")

            # Get first user message (truncated)
            first_user_msg=$(grep '"type":"user"' "$jsonl_file" 2>/dev/null | head -1 | python3 -c "
import sys, json
try:
    obj = json.loads(sys.stdin.read())
    msg = obj.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, list):
        content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
    print(content[:80])
except:
    print('?')
" 2>/dev/null || echo "?")

            local file_size
            file_size=$(du -h "$jsonl_file" | cut -f1)

            local display_name="${slug:-$session_id}"

            session_lines+=$(printf "  ${CYAN}%-40s${NC} %6s  %5d lines  %s → %s\n" \
                "$display_name" "$file_size" "$line_count" \
                "$(echo "$first_ts" | cut -c1-16)" \
                "$(echo "$last_ts" | cut -c1-16)")
            session_lines+="\n"

            if [ -n "$first_user_msg" ] && [ "$first_user_msg" != "?" ]; then
                session_lines+="    ${BOLD}ID:${NC} $session_id\n"
                session_lines+="    ${BOLD}First msg:${NC} ${first_user_msg}\n"
            else
                session_lines+="    ${BOLD}ID:${NC} $session_id\n"
            fi
            session_lines+="\n"

            session_count=$((session_count + 1))
            total=$((total + 1))
        done

        if [ $session_count -gt 0 ]; then
            # Decode project name back to path
            local decoded_path
            decoded_path=$(echo "$project_name" | sed 's/-/\//g')
            echo -e "${BOLD}Project: ${decoded_path} ${NC}($session_count sessions)"
            echo "---"
            echo -e "$session_lines"
        fi
    done

    echo -e "${BOLD}Total: $total sessions${NC}"
}

# Merge JSONL files sorted by timestamp
merge_jsonl_files() {
    local output_file="$1"
    local new_session_id="$2"
    local new_slug="$3"
    shift 3
    local input_files=("$@")

    info "Merging ${#input_files[@]} JSONL files..."

    # Use Python for reliable JSON processing and timestamp sorting
    python3 << PYEOF
import json
import sys
from datetime import datetime

input_files = $(printf '%s\n' "${input_files[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))")
new_session_id = "$new_session_id"
new_slug = "$new_slug"
output_file = "$output_file"

all_entries = []

for filepath in input_files:
    with open(filepath, 'r') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                # Store original for sorting
                ts = entry.get('timestamp', '1970-01-01T00:00:00.000Z')
                all_entries.append((ts, entry, filepath))
            except json.JSONDecodeError:
                print(f"Warning: Skipping malformed JSON at {filepath}:{line_num}", file=sys.stderr)

# Sort by timestamp
all_entries.sort(key=lambda x: x[0])

print(f"Total entries collected: {len(all_entries)}")

# Write merged output
with open(output_file, 'w') as out:
    for ts, entry, source in all_entries:
        # Update sessionId to the new merged one
        if 'sessionId' in entry:
            entry['sessionId'] = new_session_id
        # Update slug if provided
        if new_slug and 'slug' in entry:
            entry['slug'] = new_slug
        out.write(json.dumps(entry, separators=(',', ':')) + '\n')

print(f"Merged file written to: {output_file}")
PYEOF
}

# Copy subagent files from source sessions
copy_subagents() {
    local target_dir="$1"
    local new_session_id="$2"
    shift 2
    local session_ids=("$@")

    local subagent_target="$target_dir/$new_session_id/subagents"

    for sid in "${session_ids[@]}"; do
        local project_dir
        project_dir=$(find_session_project "$sid")
        [ -z "$project_dir" ] && continue

        local subagent_dir="$project_dir$sid/subagents"
        if [ -d "$subagent_dir" ]; then
            mkdir -p "$subagent_target"
            info "Copying subagents from session $sid..."
            for agent_file in "$subagent_dir"/*.jsonl; do
                [ -f "$agent_file" ] || continue
                local agent_name
                agent_name=$(basename "$agent_file")
                # Avoid collisions by prefixing with source session ID if needed
                if [ -f "$subagent_target/$agent_name" ]; then
                    local base="${agent_name%.jsonl}"
                    cp "$agent_file" "$subagent_target/${base}-from-${sid:0:8}.jsonl"
                else
                    cp "$agent_file" "$subagent_target/$agent_name"
                fi
            done
        fi
    done
}

# Update sessions-index.json
update_session_index() {
    local project_dir="$1"
    local new_session_id="$2"
    local new_slug="$3"
    local merged_jsonl="$4"

    local index_file="$project_dir/sessions-index.json"

    # Get metadata from the merged file
    local first_ts last_ts line_count
    first_ts=$(head -1 "$merged_jsonl" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp',''))" 2>/dev/null || echo "")
    last_ts=$(tail -1 "$merged_jsonl" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp',''))" 2>/dev/null || echo "")
    line_count=$(wc -l < "$merged_jsonl" | tr -d ' ')

    if [ -f "$index_file" ]; then
        info "Updating sessions-index.json..."
        python3 << PYEOF
import json

index_file = "$index_file"
new_id = "$new_session_id"
new_slug = "$new_slug"
first_ts = "$first_ts"
last_ts = "$last_ts"
line_count = $line_count

try:
    with open(index_file, 'r') as f:
        index = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    index = {}

# Add new session entry
if isinstance(index, dict):
    # Format varies - could be a dict keyed by session ID or have a sessions array
    index[new_id] = {
        "id": new_id,
        "name": new_slug or "merged-session",
        "slug": new_slug or "merged-session",
        "createdAt": first_ts,
        "lastActivityAt": last_ts,
        "messageCount": line_count,
        "merged": True,
        "mergedAt": "$( date -u +%Y-%m-%dT%H:%M:%S.000Z )"
    }
elif isinstance(index, list):
    index.append({
        "id": new_id,
        "name": new_slug or "merged-session",
        "slug": new_slug or "merged-session",
        "createdAt": first_ts,
        "lastActivityAt": last_ts,
        "messageCount": line_count,
        "merged": True
    })

with open(index_file, 'w') as f:
    json.dump(index, f, indent=2)

print(f"Updated {index_file}")
PYEOF
    else
        info "No sessions-index.json found, skipping index update."
    fi
}

# Delete source sessions
delete_sources() {
    local session_ids=("$@")

    for sid in "${session_ids[@]}"; do
        local project_dir
        project_dir=$(find_session_project "$sid")
        [ -z "$project_dir" ] && continue

        warn "Deleting session $sid..."

        # Delete JSONL file
        rm -f "$project_dir$sid.jsonl"

        # Delete subagent directory
        rm -rf "$project_dir$sid/"

        # Delete related files in other locations
        rm -f "$CLAUDE_DIR/debug/$sid.txt"
        rm -rf "$CLAUDE_DIR/session-env/$sid/"

        # Remove from todos
        for todo_file in "$CLAUDE_DIR/todos/${sid}"*.json; do
            [ -f "$todo_file" ] && rm -f "$todo_file"
        done
    done
}

# Find all split sessions (same slug across multiple sessions)
find_splits() {
    info "Scanning all sessions for splits..."
    echo ""

    declare -A slug_map      # slug -> "project_dir|session_id|size|lines|first_ts|last_ts|first_msg"
    declare -A slug_count    # slug -> count of sessions with this slug
    declare -a split_slugs   # list of slugs that have splits

    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue

        local project_name
        project_name=$(basename "$project_dir")

        for jsonl_file in "$project_dir"*.jsonl; do
            [ -f "$jsonl_file" ] || continue

            local session_id
            session_id=$(basename "$jsonl_file" .jsonl)

            # Skip if not a UUID-like pattern
            if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
                continue
            fi

            # Get metadata
            local slug=""
            local first_ts=""
            local last_ts=""
            local line_count=0
            local file_size=""
            local first_user_msg=""

            line_count=$(wc -l < "$jsonl_file" | tr -d ' ')
            slug=$(grep -o '"slug":"[^"]*"' "$jsonl_file" 2>/dev/null | tail -1 | sed 's/"slug":"//;s/"//' || echo "")
            first_ts=$(head -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")
            last_ts=$(tail -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")
            file_size=$(du -h "$jsonl_file" | cut -f1)

            first_user_msg=$(grep '"type":"user"' "$jsonl_file" 2>/dev/null | head -1 | python3 -c "
import sys, json
try:
    obj = json.loads(sys.stdin.read())
    msg = obj.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, list):
        content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
    print(content[:80])
except:
    print('?')
" 2>/dev/null || echo "?")

            # Store session data keyed by slug
            if [ -n "$slug" ]; then
                local key="${slug}|${project_dir}|${session_id}|${file_size}|${line_count}|${first_ts}|${last_ts}|${first_user_msg}"
                
                # Check if this slug already exists
                if [ -n "${slug_map[$slug]:-}" ]; then
                    slug_map[$slug]+="
${key}"
                    slug_count[$slug]=$((${slug_count[$slug]:-1} + 1))
                    # Mark this slug as having splits if not already marked
                    if ! printf '%s
' "${split_slugs[@]:-}" | grep -q "^${slug}$"; then
                        split_slugs+=("$slug")
                    fi
                else
                    slug_map[$slug]="$key"
                    slug_count[$slug]=1
                fi
            fi
        done
    done

    # Display results
    if [ ${#split_slugs[@]} -eq 0 ]; then
        success "No split sessions found! All session slugs are unique."
        return
    fi

    echo -e "${BOLD}Found ${#split_slugs[@]} split session groups:${NC}"
    echo "=========================================="
    echo ""

    local total_sessions=0

    for slug in "${split_slugs[@]}"; do
        local sessions_data="${slug_map[$slug]}"
        local count=${slug_count[$slug]}

        total_sessions=$((total_sessions + count))

        echo -e "${BOLD}${CYAN}Slug: ${slug}${NC}"
        echo "Sessions in this group: $count"
        echo ""

        # Parse and display each session in this group
        local session_num=1
        while IFS='|' read -r s_slug project_dir session_id file_size line_count first_ts last_ts first_user_msg; do
            local proj_basename
            proj_basename=$(basename "$project_dir")
            
            echo -e "  ${YELLOW}[$session_num/$count]${NC} ${CYAN}${session_id}${NC}"
            echo "      Project: $proj_basename"
            echo "      Size: $file_size ($line_count lines)"
            echo "      Date range: $(echo "$first_ts" | cut -c1-16) → $(echo "$last_ts" | cut -c1-16)"
            if [ -n "$first_user_msg" ] && [ "$first_user_msg" != "?" ]; then
                echo "      First msg: $first_user_msg"
            fi
            echo ""
            
            session_num=$((session_num + 1))
        done <<< "$sessions_data"

        # Suggest merge command
        echo -e "  ${BOLD}Merge command:${NC}"
        local session_ids=$(echo "$sessions_data" | awk -F'|' '{print $3}' | tr '
' ' ')
        echo "    merge_sessions.sh --name '$slug' --delete-sources $session_ids"
        echo ""
    done

    # Summary
    echo -e "${BOLD}Summary${NC}"
    echo "--------"
    echo "Found ${#split_slugs[@]} split session groups ($total_sessions total sessions that could be merged)"
    echo ""
    echo "To merge all splits at once, run:"
    echo -e "  ${BOLD}merge_sessions.sh --merge-splits${NC}"
}

# Automatically merge all split sessions
merge_splits() {
    info "Scanning all sessions for splits..."
    echo ""

    declare -A slug_map      # slug -> "project_dir|session_id|size|lines|first_ts|last_ts|first_msg"
    declare -A slug_count    # slug -> count
    declare -a split_slugs   # slugs with splits

    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue

        for jsonl_file in "$project_dir"*.jsonl; do
            [ -f "$jsonl_file" ] || continue

            local session_id
            session_id=$(basename "$jsonl_file" .jsonl)

            if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
                continue
            fi

            local slug=""
            slug=$(grep -o '"slug":"[^"]*"' "$jsonl_file" 2>/dev/null | tail -1 | sed 's/"slug":"//;s/"//' || echo "")

            if [ -n "$slug" ]; then
                local line_count=0
                local first_ts=""
                local last_ts=""
                local file_size=""
                local first_user_msg=""

                line_count=$(wc -l < "$jsonl_file" | tr -d ' ')
                first_ts=$(head -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")
                last_ts=$(tail -1 "$jsonl_file" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?'))" 2>/dev/null || echo "?")
                file_size=$(du -h "$jsonl_file" | cut -f1)
                first_user_msg=$(grep '"type":"user"' "$jsonl_file" 2>/dev/null | head -1 | python3 -c "
import sys, json
try:
    obj = json.loads(sys.stdin.read())
    msg = obj.get('message', {})
    content = msg.get('content', '')
    if isinstance(content, list):
        content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
    print(content[:80])
except:
    print('?')
" 2>/dev/null || echo "?")

                local key="${slug}|${project_dir}|${session_id}|${file_size}|${line_count}|${first_ts}|${last_ts}|${first_user_msg}"

                if [ -n "${slug_map[$slug]:-}" ]; then
                    slug_map[$slug]+="
${key}"
                    slug_count[$slug]=$((${slug_count[$slug]:-1} + 1))
                    if ! printf '%s
' "${split_slugs[@]:-}" | grep -q "^${slug}$"; then
                        split_slugs+=("$slug")
                    fi
                else
                    slug_map[$slug]="$key"
                    slug_count[$slug]=1
                fi
            fi
        done
    done

    if [ ${#split_slugs[@]} -eq 0 ]; then
        success "No split sessions found! Nothing to merge."
        return
    fi

    # Display what will be merged
    echo -e "${BOLD}Split sessions found (${#split_slugs[@]} groups):${NC}"
    echo ""

    local total_sessions=0
    local merge_count=0

    for slug in "${split_slugs[@]}"; do
        local count=${slug_count[$slug]}
        total_sessions=$((total_sessions + count))
        merge_count=$((merge_count + 1))

        echo -e "  [${merge_count}/${#split_slugs[@]}] ${CYAN}${slug}${NC}: $count sessions"
    done

    echo ""
    echo -e "${YELLOW}This will create ${#split_slugs[@]} merged session(s) and delete ${total_sessions} original sessions.${NC}"
    echo ""

    # Confirmation prompt
    read -p "Continue with merge? (yes/no) " -r confirm
    if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
        warn "Merge cancelled."
        return
    fi

    echo ""
    info "Starting automated merge of all split groups..."
    echo ""

    # Perform merges
    for slug in "${split_slugs[@]}"; do
        local sessions_data="${slug_map[$slug]}"
        local session_ids=()

        while IFS='|' read -r s_slug project_dir session_id rest; do
            session_ids+=("$session_id")
        done <<< "$sessions_data"

        if [ ${#session_ids[@]} -ge 2 ]; then
            info "Merging ${#session_ids[@]} sessions with slug '${slug}'..."

            # Call merge_jsonl_files and related functions
            # Use the first session's project as target
            local first_session_id="${session_ids[0]}"
            local target_project=""
            target_project=$(find_session_project "$first_session_id")

            if [ -z "$target_project" ]; then
                error "Could not find project for session $first_session_id"
            fi

            declare -a jsonl_files
            for sid in "${session_ids[@]}"; do
                local proj
                proj=$(find_session_project "$sid")
                jsonl_files+=("${proj}${sid}.jsonl")
            done

            local new_uuid
            new_uuid=$(generate_uuid)

            local merged_file="${target_project}${new_uuid}.jsonl"
            merge_jsonl_files "$merged_file" "$new_uuid" "$slug" "${jsonl_files[@]}"

            copy_subagents "$target_project" "$new_uuid" "${session_ids[@]}"
            update_session_index "$target_project" "$new_uuid" "$slug" "$merged_file"
            delete_sources "${session_ids[@]}"

            local merged_size
            merged_size=$(du -h "$merged_file" | cut -f1)
            local merged_lines
            merged_lines=$(wc -l < "$merged_file" | tr -d ' ')

            success "✓ Merged $slug: $merged_size ($merged_lines lines) → $new_uuid"
            echo ""
        fi
    done

    success "All splits merged successfully!"
}


# ── Main ──

NAME=""
DELETE_SOURCES=false
DRY_RUN=false
OUTPUT_ID=""
LIST_MODE=false
LIST_PROJECT=""
FIND_SPLITS=false
MERGE_SPLITS=false
SESSION_IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            NAME="$2"
            shift 2
            ;;
        --delete-sources)
            DELETE_SOURCES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --output-id)
            OUTPUT_ID="$2"
            shift 2
            ;;
        --list)
            LIST_MODE=true
            shift
            ;;
        --list-project)
            LIST_PROJECT="$2"
            LIST_MODE=true
            shift 2
            ;;
        --find-splits)
            FIND_SPLITS=true
            shift
            ;;
        --merge-splits)
            MERGE_SPLITS=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            SESSION_IDS+=("$1")
            shift
            ;;
    esac
done

# Check dependencies
command -v python3 >/dev/null 2>&1 || error "python3 is required"
command -v jq >/dev/null 2>&1 || warn "jq not found — some features may be limited"

# Handle list mode
if $LIST_MODE; then
    list_sessions "$LIST_PROJECT"
    exit 0
fi

# Handle find-splits mode
if $FIND_SPLITS; then
    find_splits
    exit 0
fi

# Handle merge-splits mode
if $MERGE_SPLITS; then
    merge_splits
    exit 0
fi

# Validate inputs for merge mode
if [ ${#SESSION_IDS[@]} -lt 2 ]; then
    error "At least 2 session IDs are required for merging.\nUsage: $0 <session-id-1> <session-id-2> [session-id-3 ...]\nUse --list to see available sessions."
fi

# Find all session files and verify they exist
declare -a JSONL_FILES
declare -a FOUND_PROJECTS
TARGET_PROJECT=""

for sid in "${SESSION_IDS[@]}"; do
    project_dir=$(find_session_project "$sid")
    if [ -z "$project_dir" ]; then
        error "Session $sid not found in any project under $PROJECTS_DIR"
    fi
    JSONL_FILES+=("${project_dir}${sid}.jsonl")
    FOUND_PROJECTS+=("$project_dir")

    # Use the first session's project as the target
    if [ -z "$TARGET_PROJECT" ]; then
        TARGET_PROJECT="$project_dir"
    fi
done

# Generate or use provided output ID
NEW_SESSION_ID="${OUTPUT_ID:-$(generate_uuid)}"

echo ""
echo -e "${BOLD}Session Merge Plan${NC}"
echo "========================="
echo ""
echo -e "Source sessions:"
for i in "${!SESSION_IDS[@]}"; do
    local_size=$(du -h "${JSONL_FILES[$i]}" | cut -f1)
    local_lines=$(wc -l < "${JSONL_FILES[$i]}" | tr -d ' ')
    local_slug=$(grep -o '"slug":"[^"]*"' "${JSONL_FILES[$i]}" 2>/dev/null | tail -1 | sed 's/"slug":"//;s/"//' || echo "")
    echo -e "  ${CYAN}${SESSION_IDS[$i]}${NC}"
    [ -n "$local_slug" ] && echo -e "    Name: $local_slug"
    echo -e "    Size: $local_size ($local_lines lines)"
    echo -e "    Project: $(basename "${FOUND_PROJECTS[$i]}")"
done
echo ""
echo -e "Merged session ID: ${GREEN}$NEW_SESSION_ID${NC}"
[ -n "$NAME" ] && echo -e "Merged session name: ${GREEN}$NAME${NC}"
echo -e "Target project: $(basename "$TARGET_PROJECT")"
echo -e "Delete sources: $DELETE_SOURCES"
echo ""

if $DRY_RUN; then
    warn "DRY RUN — no changes will be made."
    exit 0
fi

# Perform the merge
MERGED_FILE="${TARGET_PROJECT}${NEW_SESSION_ID}.jsonl"
merge_jsonl_files "$MERGED_FILE" "$NEW_SESSION_ID" "$NAME" "${JSONL_FILES[@]}"

# Copy subagents
copy_subagents "$TARGET_PROJECT" "$NEW_SESSION_ID" "${SESSION_IDS[@]}"

# Update session index
update_session_index "$TARGET_PROJECT" "$NEW_SESSION_ID" "$NAME" "$MERGED_FILE"

# Delete sources if requested
if $DELETE_SOURCES; then
    echo ""
    delete_sources "${SESSION_IDS[@]}"
fi

# Final summary
echo ""
merged_size=$(du -h "$MERGED_FILE" | cut -f1)
merged_lines=$(wc -l < "$MERGED_FILE" | tr -d ' ')
success "✓ Merge complete!"
echo -e "  File: $MERGED_FILE"
echo -e "  Size: $merged_size ($merged_lines lines)"
echo -e "  Session ID: $NEW_SESSION_ID"
[ -n "$NAME" ] && echo -e "  Name: $NAME"
echo ""
echo -e "Resume with: ${BOLD}claude --resume${NC} (and find '$NAME' or the new session in the picker)"
if [ -n "$NAME" ]; then
    echo -e "Or directly: ${BOLD}claude --resume '$NAME'${NC}"
fi
