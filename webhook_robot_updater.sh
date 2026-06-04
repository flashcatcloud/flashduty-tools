#!/usr/bin/env bash
set -euo pipefail

# Batch-update a webhook robot across all escalate rules that reference it.
# Uses three existing APIs: robot/list, rule/info, rule/update.
# Auth: app_key passed as query parameter (same as other flashduty tools).
#
# Supports smart matching, backup before update, and restore from backup.

##############################################################################
# Defaults & globals
##############################################################################
BASE_URL="https://api.flashcat.cloud"
APP_KEY=""
ROBOT_TYPE=""
OLD_TOKEN=""
DRY_RUN=false
AUTO_YES=false
NEW_TOKEN=""
NEW_ALIAS=""
BACKUP_FILE=""
ACTION="list"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

##############################################################################
# Helpers
##############################################################################
usage() {
    cat <<EOF
Usage:
  $(basename "$0") list    [options]           List all webhook robots
  $(basename "$0") update  [options]           Update a robot (auto-backup before update)
  $(basename "$0") restore [options]           Restore rules from a backup file

Common options:
  --base-url URL        API base URL (default: https://api.flashcat.cloud)
  --app-key  KEY        App key for authentication (required)
  --type     TYPE       Robot type filter: feishu, dingtalk, wecom, slack, telegram, zoom

Update options:
  --token     TOKEN     Current token/URL of the robot to update (required)
  --new-token TOKEN     New token/URL to replace with
  --new-alias ALIAS     New alias/display name
  --dry-run             Show what would change without actually updating
  --yes                 Skip confirmation prompts

Restore options:
  --backup    FILE      Backup file to restore from (required)
  --yes                 Skip confirmation prompts

Examples:
  $(basename "$0") list --app-key YOUR_KEY

  $(basename "$0") update --app-key YOUR_KEY \\
      --type wecom --token "old-token" --new-token "new-token"

  $(basename "$0") restore --app-key YOUR_KEY --backup webhook_backup_20260604_160000.json
EOF
    exit 1
}

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }

check_deps() {
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_err "Missing dependency: $cmd"
            exit 1
        fi
    done
}

api_post() {
    local path="$1"
    local body="$2"
    local url="${BASE_URL}${path}?app_key=${APP_KEY}"

    local resp
    resp=$(printf '%s' "$body" | curl -s --max-time 30 -w "\n%{http_code}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null) || true

    local http_code
    http_code="${resp##*$'\n'}"
    local response_body
    response_body="${resp%$'\n'*}"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_err "API call failed: $path (HTTP $http_code)"
        log_err "Response: $response_body"
        return 1
    fi

    printf '%s' "$response_body" | jq -c 'if .data != null then .data else . end'
}

JQ_EXTRACT_KEY='def extract_key:
  if test("[:?&]key=") then split("key=") | last | split("&") | first
  elif test("access_token=") then split("access_token=") | last | split("&") | first
  else .
  end;'

##############################################################################
# Parse arguments
##############################################################################
parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    case "$1" in
        -h|--help) usage ;;
    esac

    ACTION="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url)  BASE_URL="$2";    shift 2 ;;
            --app-key)   APP_KEY="$2";     shift 2 ;;
            --type)      ROBOT_TYPE="$2";  shift 2 ;;
            --token)     OLD_TOKEN="$2";   shift 2 ;;
            --new-token) NEW_TOKEN="$2";   shift 2 ;;
            --new-alias) NEW_ALIAS="$2";   shift 2 ;;
            --backup)    BACKUP_FILE="$2"; shift 2 ;;
            --dry-run)   DRY_RUN=true;     shift   ;;
            --yes)       AUTO_YES=true;    shift   ;;
            -h|--help)   usage ;;
            *)           log_err "Unknown option: $1"; usage ;;
        esac
    done

    BASE_URL="${BASE_URL%/}"

    if [[ -z "$APP_KEY" ]]; then
        log_err "--app-key is required"
        exit 1
    fi
}

##############################################################################
# Action: list
##############################################################################
do_list() {
    log_info "Fetching robot list..."

    local body='{}'
    if [[ -n "$ROBOT_TYPE" ]]; then
        body=$(jq -n --arg t "$ROBOT_TYPE" '{"type": $t}')
    fi

    local resp
    resp=$(api_post "/channel/escalate/webhook/robot/list" "$body") || exit 1

    local count
    count=$(printf '%s' "$resp" | jq '.list | length')

    if [[ "$count" -eq 0 ]]; then
        log_warn "No robots found."
        return
    fi

    echo ""
    echo -e "${CYAN}Found $count robot(s):${NC}"
    echo "================================================================"

    local idx=0
    printf '%s' "$resp" | jq -r '.list[] | @base64' | while read -r item; do
        idx=$((idx + 1))
        local decoded
        decoded=$(echo "$item" | base64 -d 2>/dev/null || echo "$item" | base64 -D 2>/dev/null)

        local rtype alias token ref_count
        rtype=$(printf '%s' "$decoded" | jq -r '.type // "unknown"')
        alias=$(printf '%s' "$decoded" | jq -r '.settings.alias // "(no alias)"')
        token=$(printf '%s' "$decoded" | jq -r '.settings.token // "(no token)"')
        ref_count=$(printf '%s' "$decoded" | jq '.referenced_by | length')

        echo -e "  #${idx}"
        echo -e "  Type:       ${GREEN}${rtype}${NC}"
        echo -e "  Alias:      ${alias}"
        echo -e "  Token/URL:  ${token}"
        echo -e "  Referenced:  ${ref_count} escalate rule(s)"

        printf '%s' "$decoded" | jq -r '.referenced_by[]? | "    -> [\(.channel_name // "channel:\(.channel_id)")] \(.escalate_rule_name // .escalate_rule_id)"'

        echo "----------------------------------------------------------------"
    done
}

##############################################################################
# Action: update
##############################################################################
do_update() {
    if [[ -z "$OLD_TOKEN" ]]; then
        log_err "--token is required for update"
        exit 1
    fi
    if [[ -z "$NEW_TOKEN" && -z "$NEW_ALIAS" ]]; then
        log_err "At least one of --new-token or --new-alias is required"
        exit 1
    fi
    if [[ -z "$ROBOT_TYPE" ]]; then
        log_err "--type is required for update"
        exit 1
    fi

    echo -ne "${CYAN}[INFO]${NC}  Searching for robot: type=${ROBOT_TYPE}, token=${OLD_TOKEN}..."
    local t_search=$SECONDS

    local list_body
    list_body=$(jq -n --arg t "$ROBOT_TYPE" '{"type": $t}')

    local list_resp
    list_resp=$(api_post "/channel/escalate/webhook/robot/list" "$list_body") || exit 1
    echo " ($((SECONDS - t_search))s)"

    local matches
    matches=$(printf '%s' "$list_resp" | jq --arg tok "$OLD_TOKEN" "${JQ_EXTRACT_KEY}"'
        [.list[] | select(
            (.settings.token | extract_key) == ($tok | extract_key)
        )]
    ')

    local match_count
    match_count=$(printf '%s' "$matches" | jq 'length')

    if [[ "$match_count" -eq 0 ]]; then
        log_err "Robot not found with type=${ROBOT_TYPE} and token=${OLD_TOKEN}"
        log_info "Use '$(basename "$0") list' to see all available robots."
        exit 1
    fi

    local all_refs
    all_refs=$(printf '%s' "$matches" | jq -c '[.[].referenced_by[]] | unique_by(.escalate_rule_id)')

    local ref_count
    ref_count=$(printf '%s' "$all_refs" | jq 'length')

    local matched_tokens
    matched_tokens=$(printf '%s' "$matches" | jq -r '[.[].settings.token] | unique | join(", ")')

    local current_alias
    current_alias=$(printf '%s' "$matches" | jq -r '.[0].settings.alias // "(no alias)"')

    if [[ "$ref_count" -eq 0 ]]; then
        log_warn "Robot found but not referenced by any escalate rules. Nothing to update."
        exit 0
    fi

    echo ""
    echo -e "${CYAN}Robot found (${match_count} variant(s)):${NC}"
    echo -e "  Type:       ${ROBOT_TYPE}"
    echo -e "  Alias:      ${current_alias}"
    echo -e "  Token/URL:  ${matched_tokens}"
    echo -e "  References: ${ref_count} escalate rule(s) (deduplicated)"
    echo ""

    if [[ -n "$NEW_TOKEN" ]]; then
        echo -e "  ${YELLOW}Token/URL will change to:${NC} ${NEW_TOKEN}"
    fi
    if [[ -n "$NEW_ALIAS" ]]; then
        echo -e "  ${YELLOW}Alias will change to:${NC}     ${NEW_ALIAS}"
    fi
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN] The following rules would be updated:${NC}"
        printf '%s' "$all_refs" | jq -r '.[] | "  -> [\(.channel_name // "channel:\(.channel_id)")] \(.escalate_rule_name // .escalate_rule_id)"'
        echo ""
        log_info "Dry-run complete. No changes were made."
        return
    fi

    if [[ "$AUTO_YES" != true ]]; then
        echo -e "${YELLOW}Affected rules:${NC}"
        printf '%s' "$all_refs" | jq -r '.[] | "  -> [\(.channel_name // "channel:\(.channel_id)")] \(.escalate_rule_name // .escalate_rule_id)"'
        echo ""
        read -r -d '' -t 0.1 -n 10000 _discard < /dev/tty 2>/dev/null || true
        read -rp "Proceed with update? [y/N] " confirm < /dev/tty
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Phase 1: fetch all rules and build backup
    local backup_json="["
    local first_entry=true
    local rules_data=""
    local refs
    refs=$(printf '%s' "$all_refs" | jq -c '.[]')

    while read -r ref; do
        [[ -z "$ref" ]] && continue

        local channel_id rule_id rule_name
        channel_id=$(printf '%s' "$ref" | jq -r '.channel_id')
        rule_id=$(printf '%s' "$ref" | jq -r '.escalate_rule_id')
        rule_name=$(printf '%s' "$ref" | jq -r '.escalate_rule_name // .escalate_rule_id')

        echo -ne "  ${CYAN}[....]${NC} Fetching [${rule_name}]..."
        local t0=$SECONDS
        local info_body
        info_body=$(jq -n --argjson cid "$channel_id" --arg rid "$rule_id" \
            '{"channel_id": $cid, "rule_id": $rid}')

        local rule_resp
        if ! rule_resp=$(api_post "/channel/escalate/rule/info" "$info_body"); then
            echo " ($((SECONDS - t0))s)"
            log_err "  Failed to fetch rule. Aborting (no changes made)."
            exit 1
        fi
        echo " ($((SECONDS - t0))s)"

        # Append to backup JSON
        local entry
        entry=$(jq -n --argjson cid "$channel_id" --arg rid "$rule_id" \
            --arg rname "$rule_name" --argjson rule "$rule_resp" \
            '{channel_id: $cid, rule_id: $rid, rule_name: $rname, original_rule: $rule}')

        if [[ "$first_entry" == true ]]; then
            backup_json="${backup_json}${entry}"
            first_entry=false
        else
            backup_json="${backup_json},${entry}"
        fi

        # Store for phase 2
        rules_data="${rules_data}${ref}|${rule_resp}"$'\n'
    done <<< "$refs"

    backup_json="${backup_json}]"

    # Save backup
    local backup_file
    backup_file="webhook_backup_$(date +%Y%m%d_%H%M%S).json"
    printf '%s' "$backup_json" | jq '.' > "$backup_file"
    echo ""
    log_info "Backup saved to: ${backup_file}"

    # Phase 2: apply updates
    local success=0
    local failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ref_part="${line%%|*}"
        local rule_resp="${line#*|}"

        local rule_name
        rule_name=$(printf '%s' "$ref_part" | jq -r '.escalate_rule_name // .escalate_rule_id')

        local jq_filter
        jq_filter=$(build_jq_update_filter)

        local jq_args=(--arg tok "$OLD_TOKEN")
        if [[ -n "$NEW_TOKEN" ]]; then
            jq_args+=(--arg new_tok "$NEW_TOKEN")
        fi
        if [[ -n "$NEW_ALIAS" ]]; then
            jq_args+=(--arg new_alias "$NEW_ALIAS")
        fi

        local new_layers
        if ! new_layers=$(printf '%s' "$rule_resp" | jq -c "${jq_args[@]}" "$jq_filter"); then
            log_err "  Failed to transform layers for [${rule_name}]. Skipping."
            failed=$((failed + 1))
            continue
        fi

        local update_body
        update_body=$(printf '%s' "$rule_resp" | jq -c \
            --argjson new_layers "$new_layers" \
            '{
                channel_id: .channel_id,
                rule_id: .rule_id,
                rule_name: .rule_name,
                description: .description,
                template_id: .template_id,
                aggr_window: .aggr_window,
                layers: $new_layers,
                time_filters: .time_filters,
                filters: .filters
            }')

        echo -ne "  ${CYAN}[....]${NC} Updating [${rule_name}]..."
        local t0=$SECONDS
        if api_post "/channel/escalate/rule/update" "$update_body" > /dev/null; then
            echo " ($((SECONDS - t0))s)"
            log_ok "  Updated successfully."
            success=$((success + 1))
        else
            echo " ($((SECONDS - t0))s)"
            log_err "  Update failed."
            failed=$((failed + 1))
        fi
    done <<< "$rules_data"

    echo ""
    log_info "Done. Updated: ${success}, Failed: ${failed}"
    log_info "To rollback: $(basename "$0") restore --app-key YOUR_KEY --backup ${backup_file}"
}

##############################################################################
# Action: restore
##############################################################################
do_restore() {
    if [[ -z "$BACKUP_FILE" ]]; then
        log_err "--backup is required for restore"
        exit 1
    fi

    if [[ ! -f "$BACKUP_FILE" ]]; then
        log_err "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    local entry_count
    entry_count=$(jq 'length' "$BACKUP_FILE")
    log_info "Loaded ${entry_count} rule(s) from: ${BACKUP_FILE}"
    echo ""

    jq -r '.[] | "  -> [channel:\(.channel_id)] \(.rule_name)"' "$BACKUP_FILE"

    if [[ "$AUTO_YES" != true ]]; then
        echo ""
        read -r -d '' -t 0.1 -n 10000 _discard < /dev/tty 2>/dev/null || true
        read -rp "Restore all rules to their original state? [y/N] " confirm < /dev/tty
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    local success=0
    local failed=0

    jq -c '.[]' "$BACKUP_FILE" | while read -r entry; do
        local rule_name
        rule_name=$(printf '%s' "$entry" | jq -r '.rule_name')

        local update_body
        update_body=$(printf '%s' "$entry" | jq -c '.original_rule | {
            channel_id: .channel_id,
            rule_id: .rule_id,
            rule_name: .rule_name,
            description: .description,
            template_id: .template_id,
            aggr_window: .aggr_window,
            layers: .layers,
            time_filters: .time_filters,
            filters: .filters
        }')

        echo -ne "  ${CYAN}[....]${NC} Restoring [${rule_name}]..."
        local t0=$SECONDS
        if api_post "/channel/escalate/rule/update" "$update_body" > /dev/null; then
            echo " ($((SECONDS - t0))s)"
            log_ok "  Restored successfully."
            success=$((success + 1))
        else
            echo " ($((SECONDS - t0))s)"
            log_err "  Restore failed."
            failed=$((failed + 1))
        fi
    done

    echo ""
    log_info "Done. Restored: ${success}, Failed: ${failed}"
}

build_jq_update_filter() {
    local updates=""
    if [[ -n "$NEW_TOKEN" ]]; then
        updates="${updates} | .settings.token = \$new_tok"
    fi
    if [[ -n "$NEW_ALIAS" ]]; then
        updates="${updates} | .settings.alias = \$new_alias"
    fi

    cat <<JQEOF
${JQ_EXTRACT_KEY}
.layers | [.[] | .target.webhooks = [
    .target.webhooks[]? |
    if (.type == "${ROBOT_TYPE}" and ((.settings.token | extract_key) == (\$tok | extract_key))) then
        (. ${updates})
    else
        .
    end
]]
JQEOF
}

##############################################################################
# Main
##############################################################################
main() {
    check_deps
    parse_args "$@"

    case "$ACTION" in
        list)    do_list    ;;
        update)  do_update  ;;
        restore) do_restore ;;
        *)       log_err "Unknown action: $ACTION"; usage ;;
    esac
}

main "$@"
