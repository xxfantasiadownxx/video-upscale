#!/bin/bash
# run.sh — Batch upscale videos to 1080p using realesr-general-x4v3
# Usage: ./run.sh

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/original_video_files"
FRAMES_DIR="$BASE_DIR/original_frame_files"
UPSCALED_FRAMES_DIR="$BASE_DIR/upscaled_frame_files"
OUTPUT_DIR="$BASE_DIR/upscaled_video_files"
SCRIPTS_DIR="$BASE_DIR/scripts"
STATUS_FILE="$BASE_DIR/status.json"
COMPOSE_LOG="$BASE_DIR/compose_run.log"

mkdir -p "$INPUT_DIR" "$FRAMES_DIR" "$UPSCALED_FRAMES_DIR" "$OUTPUT_DIR" "$SCRIPTS_DIR"

cat > "$SCRIPTS_DIR/extract.sh" << 'EOF'
#!/bin/sh
ffmpeg -hwaccel cuda -i "/original_video_files/$EPISODE_FILE" /original_frame_files/frame%08d.png
EOF

cat > "$SCRIPTS_DIR/reassemble.sh" << 'EOF'
#!/bin/sh
ffmpeg -hwaccel cuda \
  -framerate "$EPISODE_FPS" \
  -i /upscaled_frame_files/frame%08d.png \
  -i "/original_video_files/$EPISODE_FILE" \
  -map 0:v -map 1:a \
  -vf scale=-2:1080 \
  -r "$EPISODE_FPS" \
  -c:v h264_nvenc -preset p4 -rc vbr -cq 18 \
  -c:a copy \
  -vsync cfr \
  "/upscaled_video_files/$OUTPUT_FILE"
EOF

chmod +x "$SCRIPTS_DIR/extract.sh" "$SCRIPTS_DIR/reassemble.sh"

# ── Find all video files ──────────────────────────
mapfile -d '' VIDEO_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f \( \
    -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o \
    -iname "*.mov" -o -iname "*.ts"  -o -iname "*.m2ts" -o \
    -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.wmv" \
  \) -print0 | sort -z)

TOTAL_FILES=${#VIDEO_FILES[@]}
if [ "$TOTAL_FILES" -eq 0 ]; then echo "ERROR: No video files found in $INPUT_DIR"; exit 1; fi
echo ">>> Found $TOTAL_FILES file(s) to process."

BATCH_START=$(date +%s)
NAMES_FILE="$BASE_DIR/status_names.tmp"
printf '%s\n' "${VIDEO_FILES[@]}" | sed 's|.*/||' > "$NAMES_FILE"

python3 - "$NAMES_FILE" "$STATUS_FILE" "$TOTAL_FILES" "$(date +%s)" << 'PYEOF'
import json, sys
names_file, status_file, total, batch_start = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(names_file) as f:
    files = [l.rstrip('\n') for l in f if l.strip()]
status = {
  "batch_start": batch_start, "total": total, "succeeded": 0, "failed": 0,
  "current_file": "", "current_index": 0, "current_stage": "",
  "files": [{"name": fn, "status": "pending", "stage": "", "error": "", "start_time": None, "end_time": None} for fn in files]
}
with open(status_file, "w") as fp: json.dump(status, fp, indent=2)
PYEOF
rm -f "$NAMES_FILE"

update_status() {
  local index="$1" name="$2" file_status="$3" stage="$4" error="$5"
  python3 - "$STATUS_FILE" "$index" "$name" "$file_status" "$stage" "$error" "$(date +%s)" << 'PYEOF'
import json, sys
status_file, index, name, file_status, stage, error, now = \
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
with open(status_file) as fp: s = json.load(fp)
s["current_index"] = index + 1
s["current_file"] = name
s["current_stage"] = stage
s["files"][index]["status"] = file_status
s["files"][index]["stage"] = stage
s["files"][index]["error"] = error
if file_status == "done": s["succeeded"] += 1
elif file_status == "failed": s["failed"] += 1
s["elapsed"] = now - s["batch_start"]
with open(status_file, "w") as fp: json.dump(s, fp, indent=2)
PYEOF
}

set_file_time() {
  local index="$1" field="$2"
  python3 - "$STATUS_FILE" "$index" "$field" "$(date +%s)" << 'PYEOF'
import json, sys
sf, idx, field, ts = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
with open(sf) as fp: s = json.load(fp)
s["files"][idx][field] = ts
with open(sf, "w") as fp: json.dump(s, fp, indent=2)
PYEOF
}

run_compose() {
  # Usage: run_compose <compose-file> <project-name> <log-file>
  # Returns the docker compose exit code reliably.
  local compose_file="$1" project="$2" log="$3"
  : > "$log"
  EPISODE_FILE="$EPISODE_FILE" \
    EPISODE_FPS="$EPISODE_FPS" \
    OUTPUT_FILE="$OUTPUT_FILE" \
    docker compose \
      --project-directory "$BASE_DIR" \
      -f "$compose_file" \
      --project-name "$project" \
      up --abort-on-container-failure 2>&1 | tee "$log"
  # PIPESTATUS must be captured before ANY other command including local
  local exit_code
  exit_code=${PIPESTATUS[0]}
  docker compose \
    --project-directory "$BASE_DIR" \
    -f "$compose_file" \
    --project-name "$project" \
    down 2>/dev/null
  return $exit_code
}

poll_stage() {
  # Watches log file and updates status as containers complete.
  # Caller must: create sentinel file before starting, remove it to stop polling.
  local log="$1" extract_ctr="$2" upscale_ctr="$3" idx="$4" fname="$5" sentinel="$6"
  local current="extracting"
  while [ -f "$sentinel" ]; do
    sleep 3
    [ -f "$sentinel" ] || break
    if [ "$current" = "extracting" ] && \
       grep -q "${extract_ctr}.*exited with code 0" "$log" 2>/dev/null; then
      current="upscaling"
      update_status "$idx" "$fname" "running" "upscaling" ""
    fi
  done
}

SUCCEEDED=0; FAILED=0; FAILED_FILES=()

for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[$i]}"
  FILENAME=$(basename "$FILE")
  FILE_NUM=$(( i + 1 ))
  LOG_FILE="$OUTPUT_DIR/${FILENAME%.*}_error.log"
  EPISODE_FILE="$FILENAME"
  OUTPUT_FILE="${FILENAME%.*}_upscaled_1080p.mkv"

  echo ""
  echo "================================================"
  echo "  File $FILE_NUM of $TOTAL_FILES : $FILENAME"
  echo "================================================"

  set_file_time "$i" "start_time"
  update_status "$i" "$FILENAME" "running" "probing" ""

  echo ">>> Probing framerate..."
  RAW_FPS=$(docker run --rm \
    --entrypoint ffprobe \
    -v "$INPUT_DIR":/original_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -v error -select_streams v:0 \
    -of default=noprint_wrappers=1:nokey=1 \
    -show_entries stream=r_frame_rate \
    /original_video_files/"$FILENAME" 2>/dev/null | head -n 1)
  EPISODE_FPS=$(echo "$RAW_FPS" | awk -F'/' '{printf "%.3f", $1/$2}')
  EPISODE_FPS=${EPISODE_FPS:-29.97}
  echo ">>> Framerate: $EPISODE_FPS fps"

  echo ">>> Cleaning up leftover frames..."
  rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png

  # ── STAGE 1: Extract + Upscale ──────────────────
  update_status "$i" "$FILENAME" "running" "extracting" ""
  echo ">>> Extracting and upscaling..."

  # Poll in background, run compose in foreground so exit code is reliable
  POLL_SENTINEL="$BASE_DIR/.poll_active"
  touch "$POLL_SENTINEL"
  poll_stage "$COMPOSE_LOG" "restore-ffmpeg-extract" "restore-upscale" "$i" "$FILENAME" "$POLL_SENTINEL" &
  POLL_PID=$!

  run_compose "$BASE_DIR/docker-compose.yml" "upscale-general" "$COMPOSE_LOG"
  STAGE1_EXIT=$?

  rm -f "$POLL_SENTINEL"
  wait $POLL_PID 2>/dev/null

  if [ $STAGE1_EXIT -ne 0 ]; then
    ERROR_MSG=$(grep -E "(Error|error|failed|exited with code [^0])" "$COMPOSE_LOG" | tail -5)
    echo "ERROR: Extract/upscale failed for $FILENAME"
    cp "$COMPOSE_LOG" "$LOG_FILE"
    echo -e "\n=== SUMMARY ===\n$ERROR_MSG" >> "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "$ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # Real-ESRGAN writes directly as frame%08d.png — no rename needed.
  # Just verify frames are actually there before proceeding.
  echo ">>> Verifying upscaled frames..."
  UPSCALED_COUNT=$(ls "$UPSCALED_FRAMES_DIR"/frame*.png 2>/dev/null | wc -l)
  echo ">>> Found $UPSCALED_COUNT upscaled frames."

  if [ "$UPSCALED_COUNT" -eq 0 ]; then
    echo "ERROR: No upscaled frames found after renaming — upscale may have failed silently."
    echo "No upscaled frames found after rename." > "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "No upscaled frames found."
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # ── STAGE 2: Reassemble ─────────────────────────
  update_status "$i" "$FILENAME" "running" "reassembling" ""
  echo ">>> Reassembling..."

  REASSEMBLE_LOG="$BASE_DIR/reassemble_run.log"
  run_compose "$BASE_DIR/docker-compose.reassemble.yml" "upscale-general-reassemble" "$REASSEMBLE_LOG"
  STAGE2_EXIT=$?

  if [ $STAGE2_EXIT -ne 0 ]; then
    ERROR_MSG=$(grep -E "(Error|error|failed|exited with code [^0])" "$REASSEMBLE_LOG" | tail -5)
    echo "ERROR: Reassembly failed for $FILENAME"
    cat "$COMPOSE_LOG" "$REASSEMBLE_LOG" > "$LOG_FILE"
    echo -e "\n=== REASSEMBLE SUMMARY ===\n$ERROR_MSG" >> "$LOG_FILE"
    echo ">>> Error log written to $LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "Reassembly failed: $ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # ── Archive + cleanup ───────────────────────────
  echo ">>> Archiving original..."
  mv "$FILE" "$INPUT_DIR/${FILENAME%.*}_original.${FILENAME##*.}"

  echo ">>> Cleaning up frames..."
  rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png

  update_status "$i" "$FILENAME" "done" "complete" ""
  set_file_time "$i" "end_time"
  SUCCEEDED=$(( SUCCEEDED + 1 ))
  echo ">>> Done : $OUTPUT_DIR/$OUTPUT_FILE"
done

python3 - "$STATUS_FILE" "$(date +%s)" << 'PYEOF'
import json, sys
sf, now = sys.argv[1], int(sys.argv[2])
with open(sf) as fp: s = json.load(fp)
s["current_stage"] = "complete"; s["current_file"] = ""
s["elapsed"] = now - s["batch_start"]
with open(sf, "w") as fp: json.dump(s, fp, indent=2)
PYEOF

BATCH_ELAPSED=$(( $(date +%s) - BATCH_START ))
BATCH_FMT=$(printf "%02d:%02d:%02d" $(( BATCH_ELAPSED/3600 )) $(( (BATCH_ELAPSED%3600)/60 )) $(( BATCH_ELAPSED%60 )))
echo ""
echo "================================================"
echo "  Batch complete!"
echo "  Succeeded  : $SUCCEEDED / $TOTAL_FILES"
echo "  Failed     : $FAILED"
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "  Failed files:"
  for F in "${FAILED_FILES[@]}"; do echo "    - $F"; done
fi
echo "  Total time : $BATCH_FMT"
echo "  Output dir : $OUTPUT_DIR"
echo "================================================"
