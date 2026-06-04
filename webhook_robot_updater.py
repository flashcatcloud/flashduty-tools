"""
Batch-update a webhook robot across all escalate rules that reference it.

Uses three existing APIs: robot/list, rule/info, rule/update.
Auth: app_key passed as query parameter (same as other flashduty tools).

Supports smart matching: whether the user passes a full webhook URL or just
the token/key part, the script will find all robots whose token matches.
"""

import argparse
import copy
import json
import os
import sys
import time
from datetime import datetime
from urllib.parse import parse_qs, urlparse

import requests

ROBOT_TYPES = ["feishu", "dingtalk", "wecom", "slack", "telegram", "zoom"]


def extract_key(token_or_url):
    """Extract the pure key/token from a value that might be a full webhook URL.

    e.g. "https://qyapi.weixin.qq.com/...?key=abc" -> "abc"
         "https://oapi.dingtalk.com/...?access_token=abc" -> "abc"
         "abc" -> "abc"
    """
    if not token_or_url:
        return ""

    try:
        parsed = urlparse(token_or_url)
        if parsed.scheme in ("http", "https") and parsed.query:
            qs = parse_qs(parsed.query)
            for param in ("key", "access_token", "token"):
                if param in qs:
                    return qs[param][0]
    except Exception:
        pass

    return token_or_url


def tokens_match(stored_token, search_token):
    """Compare tokens with smart key extraction."""
    if stored_token == search_token:
        return True
    return extract_key(stored_token) == extract_key(search_token)


def api_post(base_url, app_key, path, body=None, timeout=30):
    url = f"{base_url.rstrip('/')}{path}"
    params = {"app_key": app_key}
    try:
        resp = requests.post(url, params=params, json=body or {}, timeout=timeout)
    except requests.Timeout:
        print(f"[ERR]  API call timed out: {path}")
        return None

    if resp.status_code < 200 or resp.status_code >= 300:
        print(f"[ERR]  API call failed: {path} (HTTP {resp.status_code})")
        print(f"[ERR]  Response: {resp.text}")
        return None

    data = resp.json()
    return data.get("data", data)


def do_list(args):
    print("[INFO] Fetching robot list...")

    body = {}
    if args.type:
        body["type"] = args.type

    resp = api_post(args.base_url, args.app_key,
                    "/channel/escalate/webhook/robot/list", body)
    if resp is None:
        sys.exit(1)

    robots = resp.get("list", [])
    if not robots:
        print("[WARN] No robots found.")
        return

    print(f"\nFound {len(robots)} robot(s):")
    print("=" * 64)

    for idx, robot in enumerate(robots, 1):
        rtype = robot.get("type", "unknown")
        settings = robot.get("settings", {})
        alias = settings.get("alias", "(no alias)")
        token = settings.get("token", "(no token)")
        refs = robot.get("referenced_by", [])

        print(f"  #{idx}")
        print(f"  Type:       {rtype}")
        print(f"  Alias:      {alias}")
        print(f"  Token/URL:  {token}")
        print(f"  Referenced:  {len(refs)} escalate rule(s)")

        for ref in refs:
            ch_name = ref.get("channel_name") or f"channel:{ref.get('channel_id')}"
            rule_name = ref.get("escalate_rule_name") or ref.get("escalate_rule_id")
            print(f"    -> [{ch_name}] {rule_name}")

        print("-" * 64)


def find_matching_robots(args):
    """Find all robots whose token matches the search token (via key extraction)."""
    body = {"type": args.type} if args.type else {}
    resp = api_post(args.base_url, args.app_key,
                    "/channel/escalate/webhook/robot/list", body)
    if resp is None:
        return []

    matched = []
    for robot in resp.get("list", []):
        stored_token = str(robot.get("settings", {}).get("token", ""))
        if tokens_match(stored_token, args.token):
            matched.append(robot)

    return matched


def merge_refs(robots):
    """Merge and deduplicate referenced_by across multiple matched robots."""
    seen = set()
    merged = []
    for robot in robots:
        for ref in robot.get("referenced_by", []):
            rule_id = ref.get("escalate_rule_id", "")
            if rule_id not in seen:
                seen.add(rule_id)
                merged.append(ref)
    return merged


def update_layers(layers, robot_type, search_token, new_token=None, new_alias=None):
    """Walk all layers, replace matching webhook settings. Returns (updated_layers, changed)."""
    updated = copy.deepcopy(layers)
    changed = False

    for layer in updated:
        target = layer.get("target")
        if not target:
            continue

        webhooks = target.get("webhooks")
        if not webhooks:
            continue

        for wh in webhooks:
            if wh.get("type") != robot_type:
                continue

            settings = wh.get("settings", {})
            stored_token = str(settings.get("token", ""))
            if not tokens_match(stored_token, search_token):
                continue

            if new_token is not None:
                settings["token"] = new_token
            if new_alias is not None:
                settings["alias"] = new_alias

            wh["settings"] = settings
            changed = True

    return updated, changed


def save_backup(backup_entries):
    """Save backup to a JSON file in the current directory. Returns the file path."""
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"webhook_backup_{ts}.json"
    with open(filename, "w", encoding="utf-8") as f:
        json.dump(backup_entries, f, ensure_ascii=False, indent=2)
    return filename


def do_update(args):
    if not args.token:
        print("[ERR]  --token is required for update")
        sys.exit(1)
    if not args.new_token and not args.new_alias:
        print("[ERR]  At least one of --new-token or --new-alias is required")
        sys.exit(1)
    if not args.type:
        print("[ERR]  --type is required for update")
        sys.exit(1)

    print(f"[INFO] Searching for robot: type={args.type}, token={args.token}", end="", flush=True)
    t0 = time.time()
    matched_robots = find_matching_robots(args)
    print(f" ({time.time() - t0:.1f}s)")
    if not matched_robots:
        print(f"[ERR]  Robot not found with type={args.type} and token={args.token}")
        print("[INFO] Use 'list' action to see all available robots.")
        sys.exit(1)

    refs = merge_refs(matched_robots)
    if not refs:
        print("[WARN] Robot found but not referenced by any escalate rules. Nothing to update.")
        sys.exit(0)

    matched_tokens = list({r.get("settings", {}).get("token", "") for r in matched_robots})
    current_alias = matched_robots[0].get("settings", {}).get("alias", "(no alias)")

    print(f"\nRobot found ({len(matched_robots)} variant(s)):")
    print(f"  Type:       {args.type}")
    print(f"  Alias:      {current_alias}")
    print(f"  Token/URL:  {', '.join(matched_tokens)}")
    print(f"  References: {len(refs)} escalate rule(s) (deduplicated)")
    print()

    if args.new_token:
        print(f"  Token/URL will change to: {args.new_token}")
    if args.new_alias:
        print(f"  Alias will change to:     {args.new_alias}")
    print()

    for ref in refs:
        ch_name = ref.get("channel_name") or f"channel:{ref.get('channel_id')}"
        rule_name = ref.get("escalate_rule_name") or ref.get("escalate_rule_id")
        print(f"  -> [{ch_name}] {rule_name}")

    if args.dry_run:
        print("\n[DRY-RUN] No changes were made.")
        return

    if not args.yes:
        print()
        try:
            import termios
            termios.tcflush(sys.stdin, termios.TCIFLUSH)
        except (ImportError, termios.error):
            pass
        confirm = input("Proceed with update? [y/N] ").strip()
        if confirm.lower() != "y":
            print("[INFO] Aborted.")
            sys.exit(0)

    # Phase 1: fetch all rules and build backup
    backup_entries = []
    rules_to_update = []

    for ref in refs:
        channel_id = ref.get("channel_id")
        rule_id = ref.get("escalate_rule_id")
        rule_name = ref.get("escalate_rule_name") or rule_id

        print(f"\n[INFO] Fetching: [channel:{channel_id}] {rule_name}", end="", flush=True)
        t0 = time.time()
        rule = api_post(args.base_url, args.app_key,
                        "/channel/escalate/rule/info",
                        {"channel_id": channel_id, "rule_id": rule_id})
        print(f" ({time.time() - t0:.1f}s)")
        if rule is None:
            print("  [ERR]  Failed to fetch rule. Aborting (no changes made).")
            sys.exit(1)

        backup_entries.append({
            "channel_id": channel_id,
            "rule_id": rule_id,
            "rule_name": rule_name,
            "original_rule": rule,
        })

        new_layers, changed = update_layers(
            rule.get("layers", []),
            args.type,
            args.token,
            new_token=args.new_token,
            new_alias=args.new_alias,
        )

        if changed:
            rules_to_update.append((ref, rule, new_layers))
        else:
            print(f"  [WARN] No matching webhook in layers. Skipping.")

    if not rules_to_update:
        print("\n[WARN] No rules to update.")
        return

    # Save backup before any writes
    backup_file = save_backup(backup_entries)
    print(f"\n[INFO] Backup saved to: {backup_file}")

    # Phase 2: apply updates
    success = 0
    failed = 0

    for ref, rule, new_layers in rules_to_update:
        channel_id = ref.get("channel_id")
        rule_name = ref.get("escalate_rule_name") or ref.get("escalate_rule_id")

        update_body = {
            "channel_id": rule["channel_id"],
            "rule_id": rule["rule_id"],
            "rule_name": rule["rule_name"],
            "description": rule.get("description", ""),
            "template_id": rule["template_id"],
            "aggr_window": rule.get("aggr_window", 0),
            "layers": new_layers,
            "time_filters": rule.get("time_filters", []),
            "filters": rule.get("filters"),
        }

        print(f"  [....] Updating [{rule_name}]...", end="", flush=True)
        t0 = time.time()
        result = api_post(args.base_url, args.app_key,
                          "/channel/escalate/rule/update", update_body)
        print(f" ({time.time() - t0:.1f}s)")
        if result is not None:
            print(f"  [ OK ] Updated successfully.")
            success += 1
        else:
            print(f"  [ERR]  Update failed.")
            failed += 1

    print(f"\n[INFO] Done. Updated: {success}, Failed: {failed}")
    print(f"[INFO] To rollback: python {sys.argv[0]} restore --app-key YOUR_KEY --backup {backup_file}")


def do_restore(args):
    if not args.backup:
        print("[ERR]  --backup is required for restore")
        sys.exit(1)

    if not os.path.isfile(args.backup):
        print(f"[ERR]  Backup file not found: {args.backup}")
        sys.exit(1)

    with open(args.backup, "r", encoding="utf-8") as f:
        backup_entries = json.load(f)

    print(f"[INFO] Loaded {len(backup_entries)} rule(s) from: {args.backup}")
    print()

    for entry in backup_entries:
        rule = entry["original_rule"]
        ch_name = f"channel:{entry['channel_id']}"
        print(f"  -> [{ch_name}] {entry['rule_name']}")

    if not args.yes:
        print()
        try:
            import termios
            termios.tcflush(sys.stdin, termios.TCIFLUSH)
        except (ImportError, termios.error):
            pass
        confirm = input("Restore all rules to their original state? [y/N] ").strip()
        if confirm.lower() != "y":
            print("[INFO] Aborted.")
            sys.exit(0)

    success = 0
    failed = 0

    for entry in backup_entries:
        rule = entry["original_rule"]
        rule_name = entry["rule_name"]

        update_body = {
            "channel_id": rule["channel_id"],
            "rule_id": rule["rule_id"],
            "rule_name": rule["rule_name"],
            "description": rule.get("description", ""),
            "template_id": rule["template_id"],
            "aggr_window": rule.get("aggr_window", 0),
            "layers": rule.get("layers", []),
            "time_filters": rule.get("time_filters", []),
            "filters": rule.get("filters"),
        }

        print(f"\n  [....] Restoring [{rule_name}]...", end="", flush=True)
        t0 = time.time()
        result = api_post(args.base_url, args.app_key,
                          "/channel/escalate/rule/update", update_body)
        print(f" ({time.time() - t0:.1f}s)")
        if result is not None:
            print(f"  [ OK ] Restored successfully.")
            success += 1
        else:
            print(f"  [ERR]  Restore failed.")
            failed += 1

    print(f"\n[INFO] Done. Restored: {success}, Failed: {failed}")


def main():
    parser = argparse.ArgumentParser(
        description="Batch-update webhook robots across escalate rules.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List all robots
  python %(prog)s list --app-key YOUR_KEY

  # Update robot token (auto-backup before update)
  python %(prog)s update --app-key YOUR_KEY \\
      --type wecom --token "old-token" --new-token "new-token"

  # Rollback from backup
  python %(prog)s restore --app-key YOUR_KEY --backup webhook_backup_20260604_160000.json
""",
    )

    parser.add_argument("action", choices=["list", "update", "restore"],
                        help="Action to perform")
    parser.add_argument("--base-url", default="https://api.flashcat.cloud",
                        help="API base URL (default: https://api.flashcat.cloud)")
    parser.add_argument("--app-key", required=True,
                        help="App key for authentication")
    parser.add_argument("--type", choices=ROBOT_TYPES, default=None,
                        help="Robot type filter")
    parser.add_argument("--token", default=None,
                        help="Current token/URL of the robot (required for update). "
                             "Accepts either the full webhook URL or just the key part.")
    parser.add_argument("--new-token", default=None,
                        help="New token/URL to replace with")
    parser.add_argument("--new-alias", default=None,
                        help="New alias/display name")
    parser.add_argument("--backup", default=None,
                        help="Backup file path (required for restore)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would change without updating")
    parser.add_argument("--yes", action="store_true",
                        help="Skip confirmation prompts")

    args = parser.parse_args()

    if args.action == "list":
        do_list(args)
    elif args.action == "update":
        do_update(args)
    elif args.action == "restore":
        do_restore(args)


if __name__ == "__main__":
    main()
