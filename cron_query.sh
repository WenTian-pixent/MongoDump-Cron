#!/bin/bash
cronTimeStamp=$(date)
timeStamp=$(date --date="$cronTimeStamp" +"%Y-%m-%dT%H:%M:%S.%3NZ")
hoursBefore="$(date --date="$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:%S.%3NZ")"
folder="/mongodump-output-query"
fileName="$timeStamp.log"
mkdir -p "$folder"
mongodump --uri="mongodb://host.docker.internal:27017" --db=playground --collection=game_rounds --query="{ \"endTime\": { \"\$gt\": { \"\$date\": \"$hoursBefore\" } , \"\$lte\": { \"\$date\": \"$timeStamp\" } } }" --out=/var/backups > "$folder/$fileName" 2>&1
echo $(date --date="$cronTimeStamp" +"%Y-%m-%d %H:%M:%S") > "/mongodump-last-run.txt"
cd /discord-bot
node index.js "$folder/$fileName"


# echo $(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
# cronTimeStamp=$(date --date="2025-09-11 12:20:00") && echo $(date --date="$cronTimeStamp - 23 hours" +"%Y-%m-%dT%H:%M:%S.000Z")
# cronTimeStamp=$(date "+%Y-%m-%dT%H:%M:%S.%3NZ") && timeStamp=$(date --date="$cronTimeStamp" +"%Y-%m-%dT%H:%M:%S.%3NZ") && hoursBefore="$(date --date="$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:%S.%3NZ")" && echo "{ \"endTime\": { \"\$gt\": $hoursBefore, \"\$lte\": $timeStamp } }"
# echo $(date -u -d $(date -d "2025-08-11 12:03:57.675"))
# echo $(date "+%Y-%m-%d %H:%M:%S.%3N")
# echo $(date --date="$date -6 days" "+%Y-%m-%d %H:%M:%S")
# cronTimeStamp=$(date --date="$1") && 
# chmod 744 /cron_query.sh && /cron_query.sh "2025-08-11 01:00:00"