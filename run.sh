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

if [ "$TOTAL_FILES" -eq 0 ]; then
  echo "ERROR: No video files found in $INPUT_DIR"
  exit 1
fi

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
  "batch_start": batch_start,
  "total": total,
  "succeeded": 0,
  "failed": 0,
  "current_file": "",
  "current_index": 0,
  "current_stage": "",
  "files": [{"name": fn, "status": "pending", "stage": "", "error": ""} for fn in files]
}
with open(status_file, "w") as fp:
    json.dump(status, fp, indent=2)
PYEOF
rm -f "$NAMES_FILE"

update_status() {
  local index="$1" name="$2" file_status="$3" stage="$4" error="$5"
  python3 - "$STATUS_FILE" "$index" "$name" "$file_status" "$stage" "$error" "$(date +%s)" << 'PYEOF'
import json, sys
status_file, index, name, file_status, stage, error, now = \
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
with open(status_file) as fp:
    s = json.load(fp)
s["current_index"] = index + 1
s["current_file"] = name
s["current_stage"] = stage
s["files"][index]["status"] = file_status
s["files"][index]["stage"] = stage
s["files"][index]["error"] = error
if file_status == "done":
    s["succeeded"] += 1
elif file_status == "failed":
    s["failed"] += 1
s["elapsed"] = now - s["batch_start"]
with open(status_file, "w") as fp:
    json.dump(s, fp, indent=2)
PYEOF
}

SUCCEEDED=0
FAILED=0
FAILED_FILES=()

for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[$i]}"
  FILENAME=$(basename "$FILE")
  FILE_NUM=$(( i + 1 ))
  LOG_FILE="$OUTPUT_DIR/${FILENAME%.*}_error.log"

  echo ""
  echo "================================================"
  echo "  File $FILE_NUM of $TOTAL_FILES : $FILENAME"
  echo "================================================"

  python3 - "$STATUS_FILE" "$i" "$(date +%s)" << 'PYEOF'
import json, sys
sf, idx, ts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(sf) as fp: s = json.load(fp)
s["files"][idx]["start_time"] = ts
s["files"][idx]["end_time"] = None
with open(sf, "w") as fp: json.dump(s, fp, indent=2)
PYEOF
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

  OUTPUT_FILE="${FILENAME%.*}_upscaled_1080p.mkv"

  echo ">>> Cleaning up leftover frames..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$UPSCALED_FRAMES_DIR"/frame*.png

  update_status "$i" "$FILENAME" "running" "extracting" ""
  : > "$COMPOSE_LOG"

  echo ">>> Starting pipeline..."

  # Run compose in background, tee to log and stdout for live visibility
  EPISODE_FILE="$FILENAME" \
    EPISODE_FPS="$EPISODE_FPS" \
    OUTPUT_FILE="$OUTPUT_FILE" \
    docker compose \
      --project-directory "$BASE_DIR" \
      --project-name upscale-general \
      up --abort-on-container-failure 2>&1 | tee "$COMPOSE_LOG" &
  COMPOSE_PID=$!

  # Poll log and advance stage as each container completes
  CURRENT_STAGE="extracting"
  while kill -0 $COMPOSE_PID 2>/dev/null; do
    if [ "$CURRENT_STAGE" = "extracting" ] && \
       grep -q "restore-ffmpeg-extract.*exited with code 0" "$COMPOSE_LOG" 2>/dev/null; then
      CURRENT_STAGE="upscaling"
      update_status "$i" "$FILENAME" "running" "upscaling" ""
    elif [ "$CURRENT_STAGE" = "upscaling" ] && \
         grep -q "restore-upscale.*exited with code 0" "$COMPOSE_LOG" 2>/dev/null; then
      CURRENT_STAGE="reassembling"
      update_status "$i" "$FILENAME" "running" "reassembling" ""
    fi
    sleep 3
  done
  wait $COMPOSE_PID
  COMPOSE_EXIT=$?

  docker compose \
    --project-directory "$BASE_DIR" \
    --project-name upscale-general \
    down 2>/dev/null

  if [ $COMPOSE_EXIT -ne 0 ]; then
    ERROR_MSG=$(grep -E "(Error|error|failed|exited with code [^0])" "$COMPOSE_LOG" | tail -5)
    echo "ERROR: Pipeline failed for $FILENAME"
    cp "$COMPOSE_LOG" "$LOG_FILE"
    {
      echo ""
      echo "=== SUMMARY ==="
      echo "$ERROR_MSG"
    } >> "$LOG_FILE"
    echo ">>> Error log written to $LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "$ERROR_MSG"
    python3 - "$STATUS_FILE" "$i" "$(date +%s)" << 'PYEOF'
import json, sys
sf, idx, ts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(sf) as fp: s = json.load(fp)
s["files"][idx]["end_time"] = ts
with open(sf, "w") as fp: json.dump(s, fp, indent=2)
PYEOF
    FAILED=$(( FAILED + 1 ))
    FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # Real-ESRGAN appends _out to filenames; rename back to frame%08d.png for ffmpeg
  echo ">>> Renaming upscaled frames..."
  COUNT=1
  for F in $(ls "$UPSCALED_FRAMES_DIR"/frame*_out.png 2>/dev/null | sort); do
    NEW=$(printf "$UPSCALED_FRAMES_DIR/frame%08d.png" $COUNT)
    mv "$F" "$NEW"
    COUNT=$(( COUNT + 1 ))
  done

  echo ">>> Archiving original..."
  mv "$FILE" "$INPUT_DIR/${FILENAME%.*}_original.${FILENAME##*.}"

  echo ">>> Cleaning up frames..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$UPSCALED_FRAMES_DIR"/frame*.png

  update_status "$i" "$FILENAME" "done" "complete" ""
  python3 - "$STATUS_FILE" "$i" "$(date +%s)" << 'PYEOF'
import json, sys
sf, idx, ts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(sf) as fp: s = json.load(fp)
s["files"][idx]["end_time"] = ts
with open(sf, "w") as fp: json.dump(s, fp, indent=2)
PYEOF
  SUCCEEDED=$(( SUCCEEDED + 1 ))
  echo ">>> Done : $OUTPUT_DIR/$OUTPUT_FILE"
done

python3 - "$STATUS_FILE" "$(date +%s)" << 'PYEOF'
import json, sys
status_file, now = sys.argv[1], int(sys.argv[2])
with open(status_file) as fp:
    s = json.load(fp)
s["current_stage"] = "complete"
s["current_file"] = ""
s["elapsed"] = now - s["batch_start"]
with open(status_file, "w") as fp:
    json.dump(s, fp, indent=2)
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
