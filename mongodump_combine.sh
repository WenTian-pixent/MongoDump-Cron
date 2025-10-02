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
# Collections To Dump
# =========================
collections=("game_rounds")

# =========================
# Keywords Indicating MongoDump Failure
# =========================
dumpFailedKeywords="ERROR|Failed|exception|could not|not authorized|authentication failed|connection refused|no such host|timeout|aborting"

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
  local collection="$1"
  local queryFile="$2"
  local dumpFolderPath="$3"
  local dumpLogFilePath="$4"
  mongodump --uri="${MONGOURL_ENV}" \
          --collection="$collection" \
          --queryFile="$queryFile" \
          --out="$dumpFolderPath" \
          --verbose 2>&1 | tee -a "$dumpLogFilePath";
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
  if [ ! -f "$failedRunFile" ]; then
      return
  fi
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
      if [ -f "$dumpLogFilePath" ]; then
          rm -f "$dumpLogFilePath"
      fi

      echo "📂 Folders created: $dumpFolderPath"
  
      create_query_file "$dateFrom" "$dateTo"

      local dump_success=false
      local upload_success=false

      local pids=()

      for collection in "${collections[@]}"; do
          # Run mongodump_query in background
          mongodump_query "$collection" "$queryFile" "$dumpFolderPath" "$dumpLogFilePath" &
          pids+=($!)
      done
      
      for pid in "${pids[@]}"; do
          wait "$pid"
          pidOutput=$?
          if [ "$pidOutput" -ne 0 ]; then
            echo "❌ mongodump command failed!" | tee -a "$dumpLogFilePath"
          fi
      done

      if grep -Eqi "$dumpFailedKeywords" "$dumpLogFilePath"; then
          echo "❌ Dump failed for $dumpFolderPath." | tee -a "$dumpLogFilePath"
      else
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
      fi

      upload_success=$(upload_s3_bucket "$dump_success" "$dumpFolderPath" "$dirTimeStamp")

      check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$dirTimeStamp"
  done
}

# =========================
#  Discord Webhooks
# =========================
DISCORD_CHANNEL="https://discord.com/api/webhooks/1423200049344549034/F1pdhO2El07djCWhm_hmFt8MpwvxOClH7IDn6V06v3Q5G6aohGe6ZI_nw9_QvfbGES27"

send_discord_notification() {
    local status="$1"
    local message="$2"
    local dirTimeStamp="$3"
    local title="${status} - ${dirTimeStamp}"
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
                \"title\": \"$title\",
                \"description\": $json_message,
                \"color\": $color
              }]
            }" \
        "$DISCORD_CHANNEL")

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
    📂 **Collection:** "${collections[@]}"
    📊 **Documents:** $docCount
    ⏱ **Dump Time (UTC):** $cronTimeStamp
    ☁️ **S3 Path:** $s3Bucket/mgc/$dirTimeStamp/"
    
        send_discord_notification "✅ SUCCESS" "$successMsg" "$dirTimeStamp"
    else
        local failMsg="📦 **Database:** $dbName
    📂 **Collection:** "${collections[@]}"
    ⏱ **Dump Time (UTC):** $cronTimeStamp
    ❌ Dump or upload failed.
    📂 Logs: $dumpLogFilePath"
    
        send_discord_notification "❌ FAILED" "$failMsg" "$dirTimeStamp"
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
if [ -f "$dumpLogFilePath" ]; then
    rm -f "$dumpLogFilePath"
fi

create_query_file "$dateFrom" "$dateTo"

# =========================
#  Run Today's MongoDump
# =========================
dump_success=false
upload_success=false

pids=()

for collection in "${collections[@]}"; do
    # Run mongodump_query in background
    mongodump_query "$collection" "$queryFile" "$dumpFolderPath" "$dumpLogFilePath" &
    pids+=($!)
done

for pid in "${pids[@]}"; do
    wait "$pid"
    pidOutput=$?
    if [ "$pidOutput" -ne 0 ]; then
      echo "❌ mongodump command failed!" | tee -a "$dumpLogFilePath"
    fi
done

echo "🔍 Running mongodump for $dbName.game_rounds ..."
if grep -Eqi "$dumpFailedKeywords" "$dumpLogFilePath"; then
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
else
    dump_success=true
    echo "✅ Dump completed successfully at $dumpFolderPath"
    re_dump_failed_cron_runs
fi

upload_success=$(upload_s3_bucket "$dump_success" "$dumpFolderPath" "$dirTimeStamp")

check_dump_upload_success "$dump_success" "$upload_success" "$dumpLogFilePath" "$dirTimeStamp"
