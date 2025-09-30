#!/bin/bash
set -uo pipefail

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
#  Paths
# =========================
basePath="/data/Microslot"
failedRunFile="$basePath/mongodump-failed-run.txt"
queryFile="$basePath/query.json"
s3Bucket="s3://msdev-mongodump"

# =========================
# Initialize functions
# =========================
create_query_file() {
  local hoursBefore="$1"
  local queryTimeStamp="$2"
  #  Create query.json file
  cat > "$queryFile" <<EOF
  {
    "endTime": {
      "\$gt": { "\$date": "$hoursBefore" },
      "\$lte": { "\$date": "$queryTimeStamp" }
    }
  }
EOF
}

mongodump_query() {
  local queryFile="$1"
  local dumpFolderPath="$2"
  local dumpLogFilePath="$3"
  mongodump --uri="${MONGOURL_ENV}" \
          --collection=game_rounds \
          --queryFile="$queryFile" \
          --out="$dumpFolderPath" \
          --verbose 2>&1 | tee "$dumpLogFilePath";
}

upload_s3_bucket() {
  #  Upload to S3
  local dump_success="$1"
  local dumpFolderPath="$2"
  local dirTimeStamp="$3"

  if [ "$dump_success" = true ]; then
      echo "📤 Uploading dump to $s3Bucket/Microslot/$dirTimeStamp/ ..." >&2
      if aws s3 cp "$dumpFolderPath" "$s3Bucket/Microslot/$dirTimeStamp/" --recursive; then
          echo "✅ Successfully uploaded to $s3Bucket/Microslot/$dirTimeStamp/" >&2
          echo "🧹 Removing local dump directory: $dumpFolderPath" >&2
          rm -rf "$dumpFolderPath"
          echo true
      else
          echo "❌ Failed to upload to S3. Keeping local copy at $dumpFolderPath." >&2
      fi
  else
      echo "❌ Skipping upload since mongodump failed." >&2
  fi
}

re_dump_failed_cron_runs() {
  mapfile -t dateLines < "$failedRunFile"

  local validDates=()
  for dateLine in "${dateLines[@]}"; do
      if date -d "$dateLine" >/dev/null 2>&1; then
      validDates+=("$dateLine")
      else
          echo "❌ Invalid date: $dateLine"
      fi
  done
  
  if [ "${#validDates[@]}" -eq 0 ]; then
      echo "❌ No valid failed dates found. Skipping re_dump_failed_cron_runs."
      return
  else
      echo "✅ Failed dates found:"
      for validDate in "${validDates[@]}"; do
          echo "$validDate"
      done
  fi

  for dateLine in "${validDates[@]}"; do
      echo "🔍 Processing date: $dateLine"
 
      local cronTimeStamp=$(date -u -d "$dateLine")
      local queryTimeStamp=$(date -u -d "$dateLine" +"%Y-%m-%dT%H:%M:00.000Z")
      local hoursBefore=$(date -u -d "$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:00.000Z")
      local dirTimeStamp=$(date -u -d "$dateLine" +"%Y-%m-%d_%H-%M-%S")
  
      echo "📅 UTC Timestamps generated"
      echo "   From: $hoursBefore"
      echo "   To:   $queryTimeStamp"
  
      local dumpFolderPath="$basePath/$dirTimeStamp"
      local dumpLogFilePath="$basePath/$dirTimeStamp.log"
      
      mkdir -p "$dumpFolderPath"
      mkdir -p "$basePath"
      echo "📂 Folders created: $dumpFolderPath"
  
      create_query_file "$hoursBefore" "$queryTimeStamp"

      local dump_success=false
      local upload_success=false

      if mongodump_query "$queryFile" "$dumpFolderPath" "$dumpLogFilePath"; then
          if grep -qi "done dumping" "$dumpLogFilePath"; then
              dump_success=true
              echo "✅ Dump completed successfully at $dumpFolderPath"
              # Remove the processed date from the file
              grep -vxF "$dateLine" "$failedRunFile" > "${failedRunFile}.tmp"
              if [ ! -s "${failedRunFile}.tmp" ]; then
                  > "$failedRunFile"
                  rm "${failedRunFile}.tmp"
              else
                  mv "${failedRunFile}.tmp" "$failedRunFile"
              fi
          else
              echo "❌ Dump failed for $dumpFolderPath." | tee -a "$dumpLogFilePath"
          fi
      else
          echo "❌ mongodump command failed!" | tee -a "$dumpLogFilePath"
      fi

      upload_success=$(upload_s3_bucket "$dump_success" "$dumpFolderPath" "$dirTimeStamp")

      check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$cronTimeStamp" "$dirTimeStamp"
  done
}

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

check_dump_upload_success() {
    local dump_success="$1"
    local upload_success="$2"
    local dumpLogFilePath="$3"
    local cronTimeStamp="$4"
    local dirTimeStamp="$5"
    # =========================
    #  Notify on Success/Failure
    # =========================
    if [ "$dump_success" = true ] && [ "$upload_success" = true ]; then
        local docCount=$(grep -oP 'done dumping.*\(\K[0-9]+' "$dumpLogFilePath" | tail -1)
        [ -z "$docCount" ] && docCount="Unknown"
    
        local successMsg="📦 **Database:** $dbName
    📂 **Collection:** game_rounds
    📊 **Documents:** $docCount
    ⏱ **Dump Time (UTC):** $cronTimeStamp
    ☁️ **S3 Path:** $s3Bucket/Microslot/$dirTimeStamp/"
    
        send_discord_notification "$DISCORD_CHANNEL_SUCCESS" "✅ SUCCESS" "$successMsg"
    else
        local failMsg="📦 **Database:** $dbName
    ⏱ **Dump Time (UTC):** $cronTimeStamp
    ❌ Dump or upload failed.
    📂 Logs: $dumpLogFilePath"
    
        send_discord_notification "$DISCORD_CHANNEL_FAILED" "❌ FAILED" "$failMsg"
    fi
}

# =========================
#  Timestamps (UTC)
# =========================
cronTimeStamp=$(date -u)
queryTimeStamp=$(date -u -d "$cronTimeStamp" +"%Y-%m-%dT%H:%M:00.000Z")
hoursBefore=$(date -u -d "$cronTimeStamp - 6 hours" +"%Y-%m-%dT%H:%M:00.000Z")
dirTimeStamp=$(date -u -d "$cronTimeStamp" +"%Y-%m-%d_%H-%M-%S")
dumpFolderPath="$basePath/$dirTimeStamp"
dumpLogFilePath="$basePath/$dirTimeStamp.log"

echo "📅 UTC Timestamps generated"
echo "   From: $hoursBefore"
echo "   To:   $queryTimeStamp"

create_query_file "$hoursBefore" "$queryTimeStamp"

# =========================
#  Run today's mongodump
# =========================
dump_success=false
upload_success=false

echo "🔍 Running mongodump for $dbName.game_rounds ..."
if mongodump_query "$queryFile" "$dumpFolderPath" "$dumpLogFilePath"; then
    if grep -qi "done dumping" "$dumpLogFilePath"; then
        dump_success=true
        echo "✅ Dump completed successfully at $dumpFolderPath"
        re_dump_failed_cron_runs
    else
        echo "❌ Dump failed for $dumpFolderPath." | tee -a "$dumpLogFilePath"
        re_dump_failed_cron_runs
        echo "$cronTimeStamp" >> "$failedRunFile"
        # Trim failedRunFile to keep only the last 20 lines if necessary
        line_count=$(wc -l < "$failedRunFile")
        if [ "$line_count" -gt 20 ]; then
            # Use a temporary file and check for errors
            tmp_file="${failedRunFile}.tmp"
            if tail -n 20 "$failedRunFile" > "$tmp_file"; then
                mv "$tmp_file" "$failedRunFile"
            else
                echo "❌ Error trimming $failedRunFile"
            fi
        fi
    fi
else
    echo "❌ mongodump command failed!" | tee -a "$dumpLogFilePath"
fi

upload_success=$(upload_s3_bucket "$dump_success" "$dumpFolderPath" "$dirTimeStamp")

check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$cronTimeStamp" "$dirTimeStamp"
