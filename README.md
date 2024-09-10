# Flashduty Tools

Welcome to the Flashduty Tools repository! This repository contains various tools and scripts for interacting with the Flashduty API and handling related tasks. 

## Requirements

- Python 3.x
- `requests` library

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/your-username/flashduty-tools.git
   cd flashduty-tools
   ```
2. Install dependences:
   ```bash
   pip install -r requirements.txt
   ```

## Usage

- **Incident Exporter**: A script to fetch incident data from the Flashduty API using cursor-based pagination and export it to a CSV file.
	1.	Open incident_exporter.py and set your API URL and app key.
	2.	Modify the start_time and end_time to the Unix timestamps for the desired time range.
   3. Run the script:
   ```bash
   python incident_exporter.py
   ```
   4.	The exported CSV file will be saved as incidents_export.csv in the same directory.
