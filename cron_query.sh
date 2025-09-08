#!/bin/bash
cronTimeStamp=$(date)
timeStamp=$(date --date="$cronTimeStamp" +"%Y-%m-%dT%H:%M:00.000Z")
hoursBefore="$(date --date="$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:00.000Z")"

folder="/mongodump-output-query"
fileName="$timeStamp.log"
mkdir -p "$folder"

dumpFolderPath="/var/backups/$fileName"
dumpLogFilePath="$folder/$fileName"
mongodump --uri="${MONGOURL_ENV}" --db=playground --collection=game_rounds --query="{ \"endTime\": { \"\$gt\": { \"\$date\": \"$hoursBefore\" } , \"\$lte\": { \"\$date\": \"$timeStamp\" } } }" --out="$dumpFolderPath" > "$dumpLogFilePath" 2>&1

if grep -qi "done dumping" "$dumpLogFilePath"; then
    # Run S3
    # If uploaded successfully, then delete the folder
    rm -r "$dumpFolderPath"
    # Else
    echo "Upload failed for $dumpFolderPath. Keeping the dump." >> "$dumpLogFilePath"
else
    echo "Dump failed for $dumpFolderPath." >> "$dumpLogFilePath"
fi

lastRunFile="/mongodump-last-run.txt"
echo $(date --date="$cronTimeStamp" +"%Y-%m-%d %H:%M:00") >> "$lastRunFile"
line_count=$(wc -l < "$lastRunFile")
if [ "$line_count" -gt 20 ]; then
  tail -n 20 "$lastRunFile" > "$lastRunFile.tmp" && mv "$lastRunFile.tmp" "$lastRunFile"
fi

# Discord Notification

message=""
errorMessage=""

if [ ! -f "$dumpLogFilePath" ] || [ ! -r "$dumpLogFilePath" ]; then
  echo "Error reading file: $dumpLogFilePath"
  exit 1
fi

fileContent=$(<"$dumpLogFilePath")

# Create message without \n & empty spaces/tabs, jq will format it correctly
if [[ "$fileContent" == *"done dumping"* ]]; then
  message+=":white_check_mark: ## MongoDump ran successfully!
**Filename:** $dumpLogFilePath
**Content:**
\`\`\`$fileContent\`\`\`
"
else
  errorMessage+=":x: ## MongoDump ran failed!
**Filename:** $dumpLogFilePath
**Content:**
\`\`\`$fileContent\`\`\`
"
fi

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