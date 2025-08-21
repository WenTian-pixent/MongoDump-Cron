#!/bin/bash
cronTimeStamp=$(date)
timeStamp=$(date --date="$cronTimeStamp" +"%Y-%m-%dT%H:%M:00.000Z")
hoursBefore="$(date --date="$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:00.000Z")"

folder="/mongodump-output-query"
fileName="$timeStamp.log"
mkdir -p "$folder"

dumpFolderPath="/var/backups/$fileName"
dumpLogFilePath="$folder/$fileName"
mongodump --uri="mongodb://host.docker.internal:27017" --db=playground --collection=game_rounds --query="{ \"endTime\": { \"\$gt\": { \"\$date\": \"$hoursBefore\" } , \"\$lte\": { \"\$date\": \"$timeStamp\" } } }" --out="$dumpFolderPath" > "$dumpLogFilePath" 2>&1

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

cd /discord-bot
# When running from cron, replace "node" with the full path to the node executable
# Perform "which node" in bash to find the path
# ex. /root/.nvm/versions/node/v22.18.0/bin/node
node index.js "$dumpLogFilePath"


# echo $(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
# cronTimeStamp=$(date --date="2025-09-11 12:20:00") && echo $(date --date="$cronTimeStamp - 23 hours" +"%Y-%m-%dT%H:%M:%S.000Z")
# cronTimeStamp=$(date "+%Y-%m-%dT%H:%M:%S.%3NZ") && timeStamp=$(date --date="$cronTimeStamp" +"%Y-%m-%dT%H:%M:%S.%3NZ") && hoursBefore="$(date --date="$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:%S.%3NZ")" && echo "{ \"endTime\": { \"\$gt\": $hoursBefore, \"\$lte\": $timeStamp } }"
# echo $(date -u -d $(date -d "2025-08-11 12:03:57.675"))
# echo $(date "+%Y-%m-%d %H:%M:%S.%3N")
# echo $(date --date="$date -6 days" "+%Y-%m-%d %H:%M:%S")
# cronTimeStamp=$(date --date="$1") && 
# chmod 744 /cron_query.sh && /cron_query.sh "2025-08-11 01:00:00"