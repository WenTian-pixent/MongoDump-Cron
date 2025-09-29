#!/bin/bash
set -euo pipefail

# =========================
#  Load environment variables
# =========================
ENV_FILE="/home/ubuntu/msdev-mongodump/MongoDump-Cron/ms-cron.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "❌ Env file $ENV_FILE not found"
  exit 1
fi

# =========================
#  Validate ENV variables
# =========================
missing=false
for envVar in "MONGOURL_ENV"; do
  if [ -z "${!envVar:-}" ]; then
    echo "❌ Error: $envVar is not set or is empty."
    missing=true
  else
    echo "✅ $envVar is set."
  fi
done

if [ "$missing" = true ]; then
  echo "❌ One or more required environment variables are missing. Exiting."
  exit 1
fi

# =========================
#  Extract DB name
# =========================
dbName=$(echo "$MONGOURL_ENV" | sed -n 's#.*/\([^?]*\).*#\1#p')
if [ -n "$dbName" ]; then
  echo "📦 Target database from URI: $dbName"
else
  dbName="demorgs"
  echo "📦 Defaulting to database: $dbName"
fi

# =========================
#  Timestamps (UTC)
# =========================
cronTimeStamp=$(date -u)
queryTimeStamp=$(date -u +"%Y-%m-%dT%H:%M:00.000Z")
hoursBefore=$(date -u -d "$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:00.000Z")
dirTimeStamp=$(date -u +"%Y-%m-%d_%H-%M-%S")

echo "📅 UTC Timestamps generated"
echo "   From: $hoursBefore"
echo "   To:   $queryTimeStamp"

# =========================
#  Paths
# =========================
basePath="/data/Microslot"
dumpFolderPath="$basePath/$dirTimeStamp"
dumpLogFilePath="$basePath/$dirTimeStamp.log"
lastRunFile="$basePath/mongodump-last-run.txt"
queryFile="$basePath/query.json"

mkdir -p "$dumpFolderPath"
mkdir -p "$basePath"
echo "📂 Folders created: $dumpFolderPath"

# =========================
#  Create query.json file
# =========================
cat > "$queryFile" <<EOF
{
  "endTime": {
    "\$gt": { "\$date": "$hoursBefore" },
    "\$lte": { "\$date": "$queryTimeStamp" }
  }
}
EOF

echo "📝 Query file created at $queryFile"

# =========================
#  Run mongodump
# =========================
dump_success=false
upload_success=false

echo "🔍 Running mongodump for $dbName.game_rounds ..."
if mongodump --uri="${MONGOURL_ENV}" \
          --collection=game_rounds \
          --queryFile="$queryFile" \
          --out="$dumpFolderPath" \
          --verbose 2>&1 | tee "$dumpLogFilePath"; then
    if grep -qi "done dumping" "$dumpLogFilePath"; then
        dump_success=true
        echo "✅ Dump completed successfully at $dumpFolderPath"
        echo "$cronTimeStamp" > "$lastRunFile"
    else
        echo "❌ Dump failed for $dumpFolderPath." | tee -a "$dumpLogFilePath"
    fi
else
    echo "❌ mongodump command failed!" | tee -a "$dumpLogFilePath"
fi

# =========================
#  Upload to S3
# =========================
s3Bucket="s3://msdev-mongodump"

if [ "$dump_success" = true ]; then
    echo "📤 Uploading dump to $s3Bucket/Microslot/$dirTimeStamp/ ..."
    if aws s3 cp "$dumpFolderPath" "$s3Bucket/Microslot/$dirTimeStamp/" --recursive; then
        upload_success=true
        echo "✅ Successfully uploaded to $s3Bucket/Microslot/$dirTimeStamp/"
        echo "🧹 Removing local dump directory: $dumpFolderPath"
        rm -rf "$dumpFolderPath"
    else
        echo "❌ Failed to upload to S3. Keeping local copy at $dumpFolderPath."
    fi
else
    echo "❌ Skipping upload since mongodump failed."
fi

# =========================
#  Discord Webhooks
# =========================
DISCORD_CHANNEL_SUCCESS="https://discord.com/api/webhooks/1414453533733814314/xnOabt6EViC_Kq2j0Cp9CqVELcS-KPEFpKh2dNrjYBRT-L5vV883WsrVqep3iEA9f23U"
DISCORD_CHANNEL_FAILED="https://discord.com/api/webhooks/1414469964634525747/_1ZE_58m3omLE07WcLuCAP_QkEEx9emgmpsGE6pMaqaV9eUx8GUPiEY_d_8j6mARTGMJ"

send_discord_notification() {
    local webhook_url="$1"
    local status="$2"
    local message="$3"
    local color

    case "$status" in
        "✅ SUCCESS") color=3066993 ;;   # Green
        "❌ FAILED")  color=15158332 ;;  # Red
        *)            color=3447003 ;;   # Default Blue
    esac

    # Escape JSON properly
    local json_message
    json_message=$(echo "$message" | jq -Rs .)

    echo "📡 Sending Discord notification [$status] ..."

    http_code=$(curl -s -o /tmp/discord_resp.txt -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{
              \"embeds\": [{
                \"title\": \"$status\",
                \"description\": $json_message,
                \"color\": $color
              }]
            }" \
        "$webhook_url")

    if [ "$http_code" -ne 204 ]; then
        echo "❌ Failed to send Discord notification (HTTP $http_code)"
        echo "   Response: $(cat /tmp/discord_resp.txt)"
    else
        echo "✅ Discord notification sent successfully."
    fi
}

# =========================
#  Notify on Success/Failure
# =========================
if [ "$dump_success" = true ] && [ "$upload_success" = true ]; then
    docCount=$(grep -oP 'done dumping.*\(\K[0-9]+' "$dumpLogFilePath" | tail -1)
    [ -z "$docCount" ] && docCount="Unknown"

    successMsg="📦 **Database:** $dbName
📂 **Collection:** game_rounds
📊 **Documents:** $docCount
⏱ **Dump Time (UTC):** $cronTimeStamp
☁️ **S3 Path:** $s3Bucket/Microslot/$dirTimeStamp/"

    send_discord_notification "$DISCORD_CHANNEL_SUCCESS" "✅ SUCCESS" "$successMsg"
else
    failMsg="📦 **Database:** $dbName
⏱ **Dump Time (UTC):** $cronTimeStamp
❌ Dump or upload failed.
📂 Logs: $dumpLogFilePath"

    send_discord_notification "$DISCORD_CHANNEL_FAILED" "❌ FAILED" "$failMsg"
fi
