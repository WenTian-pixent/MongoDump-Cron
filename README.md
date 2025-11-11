# MongoDump-Cron

## Project Overview
This project automates MongoDB database dumps and sends notifications to Discord channels. It uses Bash shell scripts for scheduling and running dumps, processing dump logs and Curl for sending messages to Discord.

## Prerequisites
Before using this project, ensure you have the following installed:

- **MongoDB** (for `mongodump` utility)
- **CronTab** (for scheduling cron jobs)
- **jq** (for proper escaping Curl JSON payload)
- **AWS** (for uploading dump to S3 bucket)
- **tar** (for reducing dump filesize)

## File Summary
- `mongodump_daily.sh` : Bash script for dumping the previous day collection data starting from 0 hours/minutes/seconds.
- `mongodump_weekly.sh` : Bash script for dumping 7 days of collection data starting from 0 hours/minutes/seconds.

## File Summary (Legacy)
- `cron.sh` : Bash script for scheduling and running MongoDB dumps via cron jobs.
- `cron_query.sh` : Bash script for running MongoDB dumps with query filters and logging the last run time.
- `run_last_dump.sh` : Bash script for processing previous dump dates and managing dump history.
- `mongodump-last-run.txt` : Stores the last run date/time of the dump (auto-managed by scripts).
- `/mongodump-output-query` : Output folder for dump logs and results.

## Setup Instructions
1. Clone the repository and navigate to the project folder.
2. Create environment file with variables (environment file path is located in script).
3. Ensure prerequisites are installed and accessible in your environment.
4. Set up your cron jobs to execute the shell scripts as needed.

## Environment Variables
Create an environment file (e.g., `mgc-cron.env`) with the following variables:

```env
MONGOURL_ENV="mongodb+srv://user:pass@host/dbname"
DISCORD_CHANNEL="https://discord.com/api/webhooks/..."
COLLECTIONS="collection1 collection2 collection3"
DUMP_DAY_OFFSET=21
DUMP_DAY_RANGE=7
```

## Cron Instruction
```crontab
0 21 * * 0 {path to script}
```
Execute script every Monday 5:00am (+08 Malaysia Time). 

## Usage
```bash
bash mongodump.sh [YYYY-MM-DD or ISO date]
```
- **No argument:** Dumps for the current week and handles failed runs.
- **With date argument:** Dumps only for the specified date.
- The script sets the time portion of the dates to 00:00:00.
- Use the provided shell script to automate MongoDB dumps and notifications.
- Check the output logs and Discord channel for dump status updates.

## Examples
### Dump 7 days of data
```env_bash
# Current date time is 2025-11-10T21:00:00Z
DUMP_DAY_RANGE=7
bash mongodump.sh
```
- Date From: 2025-11-10T00:00:00Z
- Date To: 2025-11-17T00:00:00Z

### Dump specific date
```env_bash
DUMP_DAY_RANGE=1
bash mongodump.sh "2025-11-01"
```
- Date From: 2025-11-01T00:00:00Z
- Date To: 2025-11-02T00:00:00Z

### Dump with offset
```env_bash
# Current date time is 2025-11-24T21:00:00Z
DUMP_DAY_OFFSET=21
DUMP_DAY_RANGE=7
bash mongodump.sh
```
- Date From: 2025-11-03T00:00:00Z
- Date To: 2025-11-10T00:00:00Z

## Notes
- Make sure your scripts have execute permissions (`chmod +x script.sh`).
- Review and adjust the scripts for your specific MongoDB URI, database, and collection names.
- DUMP_DAY_OFFSET doesn't take effect if specify date to dump.

## Changelog
- v1: Initial release to dump "game_rounds" collection daily
- v1.1: Able to dump multiple collections with different query fields & re-dump failed cron runs
- v1.2: Move variables to environment file, add dump dates from last cron run logic, allow pass argument to dump specific date, put duplicate code in function
- v1.3: Change dump logic from daily to a week worth of data per weekly dump, add new env variable DUMP_DAY_RANGE

## Appendix
- **Script Functions:** 
  - `create_query_file`: Generates query for each collection.
  - `mongodump_query`: Runs mongodump for each collection in parallel.
  - `archive_dump`: Archives dump folder and generates SHA256.
  - `upload_s3_bucket`: Uploads archive and checksum to S3.
  - `verify_s3_upload`: Verifies S3 upload and checksum.
  - `send_discord_notification`: Sends status to Discord.
  - `check_final_status`: Summarizes and sends final status.
  - `re_dump_failed_cron_runs`: Retries failed dumps.
  - `dump_dates_from_last_run`: Run dump starting from the last cron run (incase of server inactivity).
  - `append_date_to_failed_run_file`: Store failed date to file for redump on the next script run.