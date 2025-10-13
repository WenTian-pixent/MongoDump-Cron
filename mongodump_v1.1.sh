#!/bin/bash
set -uo pipefail

# =========================
#  Load environment variables
# =========================
ENV_FILE="/home/ubuntu/msdev-mongodump/MongoDump-Cron/mgc-cron.env"
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
collections=("bonus_prizes" "game_round_extra_datas" "game_rounds" "player_hour_game_summaries" "player_sessions" "table_rounds" "user_table_rounds" "weekly_settlements")

# =========================
# Keywords Indicating MongoDump Failure
# =========================
dumpFailedKeywords="ERROR|Failed|exception|could not|not authorized|authentication failed|connection refused|no such host|timeout|aborting"

# =========================
#  Paths
# =========================
basePath="/data/MGC"
failedRunFile="$basePath/mongodump-failed-run.txt"
queryFile="$basePath/query.json"
s3Bucket="msdev-mongodump"

mkdir -p "$basePath"

# =========================
# Initialize functions
# =========================
create_query_file() {
  local collection="$1"
  local dateFrom="$2"
  local dateTo="$3"
  local queryField="endTime"
  
  if [[ "$collection" == "player_hour_game_summaries" || "$collection" == "weekly_settlements" ]]; then
    queryField="date"
  elif [ "$collection" == "player_sessions" ]; then
    queryField="lastBetDate"
  elif [ "$collection" == "bonus_prizes" ]; then
    queryField="createdAt"
  elif [ "$collection" == "user_table_rounds" ]; then
    queryField="updatedAt"
  fi

  cat > "$queryFile" <<EOF
{
  "$queryField": {
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

archive_dump() {
  local dumpFolderPath="$1"
  local dirTimeStamp="$2"
  local tarFilePath="$basePath/${dirTimeStamp}.tar.gz"
  local shaFilePath="$basePath/${dirTimeStamp}.tar.gz.sha256"

  echo "📦 Creating archive: $tarFilePath ..."

  if [ ! -d "$dumpFolderPath" ] || [ -z "$(ls -A "$dumpFolderPath")" ]; then
      echo "❌ Dump folder is empty. Cannot create archive."
      archive_success=false
      return
  fi

  if tar -czf "$tarFilePath" -C "$basePath" "$dirTimeStamp"; then
      echo "✅ Archive created at $tarFilePath"

      (
        cd "$basePath" || exit 1
        sha256sum "${dirTimeStamp}.tar.gz" | awk '{print $1}' > "$shaFilePath"
      )
      echo "✅ SHA256 checksum created (hash only)"

      # Save local hash in global variable for later verification
      LOCAL_HASH=$(cat "$shaFilePath")

      archive_success=true
      rm -rf "$dumpFolderPath"
  else
      echo "❌ Failed to create archive."
      archive_success=false
  fi
}

upload_s3_bucket() {
  local dirTimeStamp="$1"
  local tarFilePath="$basePath/${dirTimeStamp}.tar.gz"
  local checksumFile="$basePath/${dirTimeStamp}.tar.gz.sha256"
  local s3Prefix="MGC/$dirTimeStamp/"

  if [ "$dump_success" = true ] && [ "$archive_success" = true ]; then
      echo "📤 Uploading archive + checksum to s3://$s3Bucket/$s3Prefix ..."
      for attempt in {1..3}; do
          if aws s3 cp "$tarFilePath" "s3://$s3Bucket/$s3Prefix" && \
             aws s3 cp "$checksumFile" "s3://$s3Bucket/$s3Prefix"; then
              echo "✅ Successfully uploaded $tarFilePath and checksum"
              upload_success=true
              rm -f "$tarFilePath" "$checksumFile"   # remove after saving LOCAL_HASH
              return
          else
              echo "⚠️ Upload attempt $attempt failed. Retrying in 5s..."
              sleep 5
          fi
      done
      echo "❌ Failed to upload archive after retries."
      upload_success=false
  else
      echo "❌ Skipping upload since dump or archive failed."
      upload_success=false
  fi
}

verify_s3_upload() {
  local dirTimeStamp="$1"
  local tarFileName="${dirTimeStamp}.tar.gz"
  local checksumFileName="${tarFileName}.sha256"
  local s3Key="MGC/$dirTimeStamp/$tarFileName"
  local s3ChecksumKey="MGC/$dirTimeStamp/$checksumFileName"

  if aws s3api head-object --bucket "$s3Bucket" --key "$s3Key" >/dev/null 2>&1 && \
     aws s3api head-object --bucket "$s3Bucket" --key "$s3ChecksumKey" >/dev/null 2>&1; then
      echo "✅ Verified objects exist in S3: $s3Key"

      # Download only checksum
      tmpChecksum=$(mktemp "/tmp/${checksumFileName}.XXXX")
      if aws s3 cp "s3://$s3Bucket/$s3ChecksumKey" "$tmpChecksum" >/dev/null 2>&1; then
          echo "📥 Downloaded checksum file from S3"
          REMOTE_HASH=$(cat "$tmpChecksum")

          if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
              echo "✅ Checksum match confirmed"
              verify_success=true
          else
              echo "❌ Checksum mismatch!"
              verify_success=false
          fi
      else
          echo "❌ Failed to download checksum from S3"
          verify_success=false
      fi
      rm -f "$tmpChecksum"
  else
      echo "❌ Verification failed: archive or checksum missing in S3!"
      verify_success=false
  fi
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
        "✅ SUCCESS") color=3066993 ;;
        "❌ FAILED")  color=15158332 ;;
        *)            color=3447003 ;;
    esac

    local json_message
    json_message=$(echo "$message" | jq -Rs .)

    curl -s -o /tmp/discord_resp.txt -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{
              \"embeds\": [{
                \"title\": \"$title\",
                \"description\": $json_message,
                \"color\": $color
              } ]
            }" \
        "$DISCORD_CHANNEL" >/dev/null
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "❌ Failed to send Discord webhook (curl rc=$rc)"
    else
      echo "✅ Discord notification attempted (HTTP $(cat /tmp/discord_resp.txt))"
    fi
}

check_final_status() {
    local dumpLogFilePath="$1"
    local dirTimeStamp="$2"
    local s3Path="s3://$s3Bucket/MGC/$dirTimeStamp/$dirTimeStamp.tar.gz"

    local finalMsg="📌 **Project:** MGC/MAG

📦 **Database:** $dbName
📂 **Collection:** ${collections[@]}
⏱ **Dump Time (UTC):** $cronTimeStamp
☁️ **S3 Path:** $s3Path

**Step Results:**
- 🗃 Dump:   $( [ "$dump_success" = true ] && echo "✅ Success" || echo "❌ Failed")
- 📦 Archive: $( [ "$archive_success" = true ] && echo "✅ Success" || echo "❌ Failed")
- ☁️ Upload: $( [ "$upload_success" = true ] && echo "✅ Success" || echo "❌ Failed")
- 🔍 Verify: $( [ "$verify_success" = true ] && echo "✅ Success" || echo "❌ Failed")

📂 **Logs:** $dumpLogFilePath"

    if [ "$dump_success" = true ] && [ "$archive_success" = true ] && [ "$upload_success" = true ] && [ "$verify_success" = true ]; then
        send_discord_notification "✅ SUCCESS" "$finalMsg" "$dirTimeStamp"
    else
        send_discord_notification "❌ FAILED" "$finalMsg" "$dirTimeStamp"
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
      echo "✅ No valid failed dates found. Skipping re_dump_failed_cron_runs."
      return
  else
      echo "❌ Failed dates found:"
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
      local dumpFolderPath="$basePath/$dirTimeStamp"
      local dumpLogFilePath="$basePath/$dirTimeStamp.log"
  
      echo "📅 UTC Timestamps generated"
      echo "   From: $dateFrom"
      echo "   To:   $dateTo"

      mkdir -p "$dumpFolderPath"
      [ -f "$dumpLogFilePath" ] && rm -f "$dumpLogFilePath"
  
      dump_success=false
      archive_success=false
      upload_success=false
      verify_success=false
      LOCAL_HASH=""

      local pids=()

      for collection in "${collections[@]}"; do
          create_query_file "$collection" "$dateFrom" "$dateTo"
          mongodump_query "$collection" "$queryFile" "$dumpFolderPath" "$dumpLogFilePath" &
          pids+=($!)
      done
      
      for pid in "${pids[@]}"; do
          wait "$pid" || echo "❌ mongodump process $pid failed" | tee -a "$dumpLogFilePath"
      done

      if grep -Eqi "$dumpFailedKeywords" "$dumpLogFilePath"; then
          echo "❌ Dump failed for $dumpFolderPath." | tee -a "$dumpLogFilePath"
          dump_success=false
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

      if [ "$dump_success" = true ]; then
          archive_dump "$dumpFolderPath" "$dirTimeStamp"
          upload_s3_bucket "$dirTimeStamp"
          verify_s3_upload "$dirTimeStamp"
      fi

      check_final_status "$dumpLogFilePath" "$dirTimeStamp"
  done
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
[ -f "$dumpLogFilePath" ] && rm -f "$dumpLogFilePath"

# =========================
#  Run MongoDump
# =========================
dump_success=false
archive_success=false
upload_success=false
verify_success=false
LOCAL_HASH=""

pids=()
for collection in "${collections[@]}"; do
    create_query_file "$collection" "$dateFrom" "$dateTo"
    mongodump_query "$collection" "$queryFile" "$dumpFolderPath" "$dumpLogFilePath" &
    pids+=($!)
done

for pid in "${pids[@]}"; do
    wait "$pid" || echo "❌ mongodump process $pid failed" | tee -a "$dumpLogFilePath"
done

if grep -Eqi "$dumpFailedKeywords" "$dumpLogFilePath"; then
    echo "❌ Dump failed for $dumpFolderPath."
    dump_success=false
else
    dump_success=true
    echo "✅ Dump completed successfully at $dumpFolderPath"
fi

# =========================
# Archive + Upload + Verify
# =========================
if [ "$dump_success" = true ]; then
    archive_dump "$dumpFolderPath" "$dirTimeStamp"
    upload_s3_bucket "$dirTimeStamp"
    verify_s3_upload "$dirTimeStamp"
fi

check_final_status "$dumpLogFilePath" "$dirTimeStamp"

re_dump_failed_cron_runs

echo "$dateFrom" >> "$failedRunFile"
# Trim failedRunFile to keep only the last 20 lines if necessary
line_count=$(wc -l < "$failedRunFile")
if [ "$line_count" -gt 20 ]; then
    # Use a temporary file and check for errors
    tmp_file="${failedRunFile}.tmp"
    if tail -n 20 "$failedRunFile" > "$tmp_file"; then
        mv -f "$tmp_file" "$failedRunFile"
    else
        echo "❌ Error trimming $failedRunFile"
    fi
fi