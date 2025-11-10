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
2. Enter following credentials to ~/.bashrc:
    - MongoDB database URL
    - Discord Channel ID
3. Ensure MongoDB and `mongodump` are installed and accessible in your environment.
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

## Usage
```bash
bash mongodump_weekly.sh [YYYY-MM-DD or ISO date]
```
- **No argument:** Dumps for the current week and handles failed runs.
- **With date argument:** Dumps only for the specified date.
- Use the provided shell scripts to automate MongoDB dumps and notifications.
- Check the output logs and Discord channels for dump status updates.

## Notes
- Make sure your scripts have execute permissions (`chmod +x script.sh`).
- Review and adjust the scripts for your specific MongoDB URI, database, and collection names.

## Changelog
- v1: Initial release to dump "game_rounds" collection daily
- v1.1: Able to dump multiple collections with different query fields & re-dump failed cron runs
- v1.2: Move variables to environment file, add dump dates from last cron run logic, allow pass argument to dump specific date, put duplicate code in function
- v1.3: Change dump logic from daily to a week worth of data per weekly dump, add new env variable DUMP_DAY_RANGE