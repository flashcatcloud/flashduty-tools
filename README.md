# Flashduty Tools

Welcome to the Flashduty Tools repository! This repository contains various tools and scripts for interacting with the Flashduty API and handling related tasks.

## Requirements

- Python 3.x
- `requests` library
- `curl` and `jq` (for shell scripts)

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/flashcatcloud/flashduty-tools.git
   cd flashduty-tools
   ```
2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Usage

- **Incident Exporter**: A script to fetch incident data from the Flashduty API using cursor-based pagination and export it to a CSV file.
   1. Open `incident_exporter.py` and set your API URL and app key.
   2. Modify the `start_time` and `end_time` to the Unix timestamps for the desired time range.
   3. Run the script:
   ```bash
   python incident_exporter.py
   ```
   4. The exported CSV file will be saved as `incidents_export.csv` in the same directory.

- **Webhook Robot Updater**: Batch-update a webhook robot's token/URL or alias across all escalate rules that reference it. Available in both Shell and Python versions.

   **Step 1: List all robots** (see what's currently configured):
   ```bash
   # Shell version (default base-url: https://api.flashcat.cloud)
   bash webhook_robot_updater.sh list --app-key YOUR_KEY

   # Python version
   python webhook_robot_updater.py list --app-key YOUR_KEY

   # Filter by type (feishu, dingtalk, wecom, slack, telegram, zoom)
   python webhook_robot_updater.py list --app-key YOUR_KEY --type feishu
   ```

   **Step 2: Preview changes** (dry-run, no actual modifications):
   ```bash
   python webhook_robot_updater.py update --app-key YOUR_KEY \
       --type feishu --token "current-token-or-url" \
       --new-token "new-token-or-url" --dry-run
   ```

   **Step 3: Apply changes**:
   ```bash
   python webhook_robot_updater.py update --app-key YOUR_KEY \
       --type feishu --token "current-token-or-url" \
       --new-token "new-token-or-url"
   ```

   Options:
   - `--new-token` — Replace the webhook token/URL
   - `--new-alias` — Replace the display name
   - `--dry-run` — Preview only, no changes
   - `--yes` — Skip confirmation prompts
