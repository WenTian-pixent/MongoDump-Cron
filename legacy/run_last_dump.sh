#!/bin/bash

# Check if required environment variables are set
for envVar in "MONGOURL_ENV" "DISCORD_CHANNEL_SUCCESS" "DISCORD_CHANNEL_ABC"; do
  if [ -z "${!envVar}" ]; then
    echo "Error: $envVar is not set or is empty."
    exit 1
done

# Read the last run date from the file
dumpLastRun=$(tail -n 1 "/mongodump-last-run.txt")
if ! date --date="$dumpLastRun" >/dev/null 2>&1; then
    echo "Invalid date: $dumpLastRun"
    exit 1
fi

# Create output directory
folder="/mongodump-output-last-run"
mkdir -p "$folder"

# Calculate the number of days between the last run date and today
dateDumpLastRun=$(date --date="$dumpLastRun")
todayDate=$(date)

numberOfDays=$(( ($(date "+%s") - $(date --date="$dateDumpLastRun" +"%s")) / 86400 ))

if [ $numberOfDays -le 0 ]; then
    echo "The last dump date is today or in the future. Exiting."
    exit 1
fi

args=()
# Loop through each day and perform mongodump
for ((i=1; i<=numberOfDays; i++)); do
    dateToDump=$(date --date="$dateDumpLastRun + $i days" +"%Y-%m-%dT%H:%M:%S.%3NZ")
    startOfDate=$(date --date="$dateToDump" +"%Y-%m-%dT00:00:00.000Z")
    endOfDate=$(date --date="$dateToDump" +"%Y-%m-%dT23:59:59.999Z")
    fileName="$dateToDump.log"

    dumpFolderPath="/var/backups/$fileName"
    dumpLogFilePath="$folder/$fileName"
    mongodump --uri="${MONGOURL_ENV}" --db=playground --collection=game_rounds --query="{ \"endTime\": { \"\$gt\": { \"\$date\": \"$startOfDate\" } , \"\$lte\": { \"\$date\": \"$endOfDate\" } } }" --out="$dumpFolderPath" > "$dumpLogFilePath" 2>&1

    if grep -qi "done dumping" "$dumpLogFilePath"; then
        # Run S3
        # If uploaded successfully, then delete the folder
        rm -r "$dumpFolderPath"
        # Else
        echo "Upload failed for $dumpFolderPath. Keeping the dump." >> "$dumpLogFilePath"
    else
        echo "Dump failed for $dumpFolderPath." >> "$dumpLogFilePath"
    fi

    args+=("$dumpLogFilePath")
done

# Discord Notification

message=""
errorMessage=""

# Loop through all log files and create messages
for file in "${args[@]}"; do
  # Read the log file content
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "Error reading file: $file"
    exit 1
  fi

  fileContent=$(<"$file")
  # Create message without \n & empty spaces/tabs, jq will format it correctly
  if [[ "$fileContent" == *"done dumping"* ]]; then
    message+=":white_check_mark: ## MongoDump ran successfully!
**Filename:** $file
**Content:**
\`\`\`$fileContent\`\`\`
"
  else
    errorMessage+=":x: ## MongoDump ran failed!
**Filename:** $file
**Content:**
\`\`\`$fileContent\`\`\`
"
  fi
done

call_discord_webhook() {
    payload=$(jq -n --arg content "$1" '{ content: $content }')
    curl -H "Content-Type: application/json" \
     -X POST \
     -d "$payload" \
     "$2"
}

if [ -n "$message" ]; then
  call_discord_webhook "$message" "$DISCORD_CHANNEL_SUCCESS"
fi

if [ -n "$errorMessage" ]; then
  call_discord_webhook "$errorMessage" "$DISCORD_CHANNEL_FAILED"
fi