#!/bin/bash
dumpLastRun=$(tail -n 1 "/mongodump-last-run.txt")
if ! date --date="$dumpLastRun" >/dev/null 2>&1; then
    echo "Invalid date: $dumpLastRun"
    exit 1
fi

folder="/mongodump-output-last-run"
mkdir -p "$folder"

dateDumpLastRun=$(date --date="$dumpLastRun")
todayDate=$(date)

numberOfDays=$(( ($(date "+%s") - $(date --date="$dateDumpLastRun" +"%s")) / 86400 ))

if [ $numberOfDays -le 0 ]; then
    echo "The last dump date is today or in the future. Exiting."
    exit 1
fi

args=()
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

./discord_curl.sh "${args[@]}"

# cd /discord-bot
# When running from cron, replace "node" with the full path to the node executable
# Perform "which node" in bash to find the path
# ex. /root/.nvm/versions/node/v22.18.0/bin/node
# node index.js ${args[@]}