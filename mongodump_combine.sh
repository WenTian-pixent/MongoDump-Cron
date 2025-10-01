#!/bin/bash
set -uo pipefail

# =========================
#  Load environment variables
# =========================
ENV_FILE="/home/ubuntu/mgcdev-mongodump/MongoDump-Cron/mgc-cron.env"
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
  dbName="aggregator"
  echo "📦 Defaulting to database: $dbName"
fi

# =========================
#  Paths
# =========================
basePath="/data/mgc"
failedRunFile="$basePath/mongodump-failed-run.txt"
queryFile="$basePath/query.json"
s3Bucket="s3://mgcdev-mongodump"

mkdir -p "$basePath"

# =========================
# Initialize functions
# =========================
create_query_file() {
  local dateFrom="$1"
  local dateTo="$2"
  #  Create query.json file
  cat > "$queryFile" <<EOF
  {
    "endTime": {
      "\$gte": { "\$date": "$dateFrom" },
      "\$lt": { "\$date": "$dateTo" }
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
  local dump_success="$1"
  local dumpFolderPath="$2"
  local dirTimeStamp="$3"

  if [ "$dump_success" = true ]; then
      echo "📤 Uploading dump to $s3Bucket/mgc/$dirTimeStamp/ ..." >&2
      if aws s3 cp "$dumpFolderPath" "$s3Bucket/mgc/$dirTimeStamp/" --recursive; then
          echo "✅ Successfully uploaded to $s3Bucket/mgc/$dirTimeStamp/" >&2
          echo "🧹 Removing local dump directory: $dumpFolderPath" >&2
          rm -rf "$dumpFolderPath"
          echo true # Function return upload success to variable
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
      echo "🔍 Processing failed date: $dateLine"
 
      local failedDate=$(date -u -d "$dateLine")
      local dateFrom=$(date -u -d "$failedDate" +"%Y-%m-%dT00:00:00Z")
      local dateTo=$(date -u -d "$failedDate + 1 day" +"%Y-%m-%dT00:00:00Z")
      local dirTimeStamp="${dbName}_$(date -u -d "$dateFrom" +"%Y-%m-%d_00-00-00")"
  
      echo "📅 UTC Timestamps generated"
      echo "   From: $dateFrom"
      echo "   To:   $dateTo"
  
      local dumpFolderPath="$basePath/$dirTimeStamp"
      local dumpLogFilePath="$basePath/$dirTimeStamp.log"
      
      mkdir -p "$dumpFolderPath"

      echo "📂 Folders created: $dumpFolderPath"
  
      create_query_file "$dateFrom" "$dateTo"

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

      check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$dirTimeStamp"
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
    local dirTimeStamp="$4"
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
    ☁️ **S3 Path:** $s3Bucket/mgc/$dirTimeStamp/"
    
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
#  Today's Timestamps (UTC)
# =========================
cronTimeStamp=$(date -u)
dateFrom=$(date -u -d "$cronTimeStamp - 20 days" +"%Y-%m-%dT00:00:00Z")
dateTo=$(date -u -d "$cronTimeStamp - 19 days" +"%Y-%m-%dT00:00:00Z")
dirTimeStamp="${dbName}_$(date -u -d "$dateFrom" +"%Y-%m-%d_00-00-00")"
dumpFolderPath="$basePath/$dirTimeStamp"
dumpLogFilePath="$basePath/$dirTimeStamp.log"

echo "📅 UTC Timestamps generated"
echo "   From: $dateFrom"
echo "   To:   $dateTo"

mkdir -p "$dumpFolderPath"

create_query_file "$dateFrom" "$dateTo"

# =========================
#  Run Today's MongoDump
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
        echo "$dateFrom" >> "$failedRunFile"
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

check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$dirTimeStamp"
