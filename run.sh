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

cat > "$SCRIPTS_DIR/normalize.sh" << 'EOF'
#!/bin/sh
# Re-encodes any input into a known-good intermediate: CFR, deinterlaced,
# AAC stereo (or no audio track if source has none), MKV container.
# This guarantees extract/reassemble downstream always see a consistent format.
VF_CHAIN="$NORMALIZE_VF"
if [ -n "$HAS_AUDIO" ]; then
  ffmpeg -hwaccel cuda -i "/original_video_files/$EPISODE_FILE" \
    -vf "$VF_CHAIN" \
    -r "$NORMALIZE_FPS" \
    -c:v h264_nvenc -preset p4 -rc vbr -cq 16 \
    -c:a aac -b:a 192k -ac 2 \
    -vsync cfr \
    "/original_video_files/$NORMALIZED_FILE"
else
  ffmpeg -hwaccel cuda -i "/original_video_files/$EPISODE_FILE" \
    -vf "$VF_CHAIN" \
    -r "$NORMALIZE_FPS" \
    -c:v h264_nvenc -preset p4 -rc vbr -cq 16 \
    -an \
    -vsync cfr \
    "/original_video_files/$NORMALIZED_FILE"
fi
EOF

cat > "$SCRIPTS_DIR/extract.sh" << 'EOF'
#!/bin/sh
ffmpeg -hwaccel cuda -i "/original_video_files/$EPISODE_FILE" /original_frame_files/frame%08d.png
EOF

cat > "$SCRIPTS_DIR/reassemble.sh" << 'EOF'
#!/bin/sh
set -e
if [ -n "$HAS_AUDIO" ]; then
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
else
  ffmpeg -hwaccel cuda \
    -framerate "$EPISODE_FPS" \
    -i /upscaled_frame_files/frame%08d.png \
    -map 0:v \
    -vf scale=-2:1080 \
    -r "$EPISODE_FPS" \
    -c:v h264_nvenc -preset p4 -rc vbr -cq 18 \
    -vsync cfr \
    "/upscaled_video_files/$OUTPUT_FILE"
fi

# Defensive check: ffmpeg can occasionally exit 0 having written a
# truncated/empty file (e.g. disk pressure, killed encoder thread).
# Treat a missing or empty output as a hard failure.
OUT_PATH="/upscaled_video_files/$OUTPUT_FILE"
if [ ! -s "$OUT_PATH" ]; then
  echo "ERROR: output file missing or empty after reassembly: $OUT_PATH" >&2
  exit 1
fi
EOF

chmod +x "$SCRIPTS_DIR/normalize.sh" "$SCRIPTS_DIR/extract.sh" "$SCRIPTS_DIR/reassemble.sh"

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
  # cd into BASE_DIR first so ./volume paths in compose files resolve correctly.
  local compose_file="$1" project="$2" log="$3"
  : > "$log"
  (
    cd "$BASE_DIR" || exit 1
    EPISODE_FILE="$EPISODE_FILE" \
      EPISODE_FPS="$EPISODE_FPS" \
      OUTPUT_FILE="$OUTPUT_FILE" \
      HAS_AUDIO="$HAS_AUDIO" \
      docker compose \
        -f "$compose_file" \
        --project-name "$project" \
        up --abort-on-container-failure 2>&1
  ) | tee "$log"
  local exit_code
  exit_code=${PIPESTATUS[0]}
  (
    cd "$BASE_DIR" || exit 1
    docker compose \
      -f "$compose_file" \
      --project-name "$project" \
      down 2>/dev/null
  )
  # Let GPU context/memory fully release before the next container starts.
  sleep 2
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

  echo ">>> Probing source..."
  PROBE_JSON=$(docker run --rm \
    --entrypoint ffprobe \
    -v "$INPUT_DIR":/original_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate,field_order,width,height \
    -show_entries format=duration \
    -of json \
    /original_video_files/"$FILENAME" 2>/dev/null)

  RAW_FPS=$(echo "$PROBE_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d['streams'][0].get('r_frame_rate','0/0'))
except Exception:
    print('0/0')
")
  FIELD_ORDER=$(echo "$PROBE_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d['streams'][0].get('field_order','unknown'))
except Exception:
    print('unknown')
")
  DURATION_SEC=$(echo "$PROBE_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(float(d.get('format',{}).get('duration','0'))))
except Exception:
    print(0)
")
  WIDTH=$(echo "$PROBE_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(d['streams'][0].get('width',1280)))
except Exception:
    print(1280)
")
  HEIGHT=$(echo "$PROBE_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(int(d['streams'][0].get('height',720)))
except Exception:
    print(720)
")

  # Validate FPS: must parse to a sane positive number, not 0/0, inf, or nan.
  EPISODE_FPS=$(python3 -c "
raw = '$RAW_FPS'
try:
    num, den = raw.split('/')
    num, den = float(num), float(den)
    fps = num/den if den != 0 else 0
    if fps <= 0 or fps > 240 or fps != fps:  # fps!=fps catches nan
        raise ValueError
    print(f'{fps:.3f}')
except Exception:
    print('29.970')
")
  echo ">>> Detected framerate: $EPISODE_FPS fps (raw: $RAW_FPS)"

  IS_INTERLACED="false"
  case "$FIELD_ORDER" in
    tt|bb|tb|bt) IS_INTERLACED="true" ;;
  esac
  echo ">>> Field order: $FIELD_ORDER (interlaced: $IS_INTERLACED)"

  AUDIO_STREAM_COUNT=$(docker run --rm \
    --entrypoint ffprobe \
    -v "$INPUT_DIR":/original_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -v error -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    /original_video_files/"$FILENAME" 2>/dev/null | wc -l)
  if [ "$AUDIO_STREAM_COUNT" -gt 0 ]; then
    HAS_AUDIO="1"
  else
    HAS_AUDIO=""
  fi
  echo ">>> Audio streams: $AUDIO_STREAM_COUNT"

  # Disk space guard — rough estimate: raw PNG frames at source resolution,
  # roughly 3 bytes/pixel uncompressed-ish for PNG, x2 for upscaled set too.
  AVAIL_KB=$(df -Pk "$BASE_DIR" | awk 'NR==2{print $4}')
  EST_FRAMES=$(( DURATION_SEC > 0 ? DURATION_SEC * 24 : 1000 ))
  EST_BYTES_PER_FRAME=$(( WIDTH * HEIGHT * 3 ))
  EST_NEEDED_KB=$(( (EST_FRAMES * EST_BYTES_PER_FRAME * 6) / 1024 ))  # x6: orig+upscaled frames, safety margin
  if [ "$AVAIL_KB" -lt "$EST_NEEDED_KB" ]; then
    ERROR_MSG="Insufficient disk space: ~${EST_NEEDED_KB}KB estimated needed, ${AVAIL_KB}KB available."
    echo "ERROR: $ERROR_MSG"
    echo "$ERROR_MSG" > "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "$ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    continue
  fi
  echo ">>> Disk check OK: ${AVAIL_KB}KB available, ~${EST_NEEDED_KB}KB estimated needed."

  # ── STAGE 0: Normalize ───────────────────────────
  # Re-encode into a known-good intermediate (CFR, deinterlaced, AAC/none audio)
  # so extract/upscale/reassemble behave identically regardless of source format/codec.
  update_status "$i" "$FILENAME" "running" "normalizing" ""
  echo ">>> Normalizing source format..."

  if [ "$IS_INTERLACED" = "true" ]; then
    NORMALIZE_VF="yadif,format=yuv420p"
  else
    NORMALIZE_VF="format=yuv420p"
  fi
  NORMALIZE_FPS="$EPISODE_FPS"
  NORMALIZED_FILE="${FILENAME%.*}_normalized.mkv"

  LOGS_DIR="$BASE_DIR/per_file_logs"
  mkdir -p "$LOGS_DIR"
  SAFE_NAME="${FILENAME%.*}"
  NORMALIZE_LOG="$BASE_DIR/normalize_run.log"
  docker run --rm \
    -v "$INPUT_DIR":/original_video_files \
    -v "$SCRIPTS_DIR/normalize.sh":/normalize.sh:ro \
    --runtime nvidia \
    -e EPISODE_FILE="$FILENAME" \
    -e NORMALIZE_VF="$NORMALIZE_VF" \
    -e NORMALIZE_FPS="$NORMALIZE_FPS" \
    -e NORMALIZED_FILE="$NORMALIZED_FILE" \
    -e HAS_AUDIO="$HAS_AUDIO" \
    --entrypoint /bin/sh \
    jrottenberg/ffmpeg:4.4-nvidia \
    /normalize.sh \
    > "$NORMALIZE_LOG" 2>&1
  NORMALIZE_EXIT=$?
  sleep 2  # let GPU context release before extract/upscale start
  cp "$NORMALIZE_LOG" "$LOGS_DIR/${SAFE_NAME}_normalize.log" 2>/dev/null

  if [ $NORMALIZE_EXIT -ne 0 ] || [ ! -f "$INPUT_DIR/$NORMALIZED_FILE" ]; then
    ERROR_MSG=$(grep -E "(Error|error|failed)" "$NORMALIZE_LOG" | tail -5)
    echo "ERROR: Normalization failed for $FILENAME"
    cp "$NORMALIZE_LOG" "$LOG_FILE"
    echo -e "\n=== NORMALIZE SUMMARY ===\n$ERROR_MSG" >> "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "Normalization failed: $ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    continue
  fi

  echo ">>> Normalized: $NORMALIZED_FILE — removing original source."
  rm -f "$FILE"
  # From this point forward, operate on the normalized file.
  EPISODE_FILE="$NORMALIZED_FILE"
  FILE="$INPUT_DIR/$NORMALIZED_FILE"

  # Re-probe audio on the NORMALIZED file. The pre-normalize HAS_AUDIO flag
  # reflects the original source; if normalization dropped or failed to
  # carry the audio track for any reason, reassembly's -map 1:a would
  # otherwise fail with "Stream map matches no streams" (exit 1, no output).
  NORMALIZED_AUDIO_COUNT=$(docker run --rm \
    --entrypoint ffprobe \
    -v "$INPUT_DIR":/original_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -v error -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    /original_video_files/"$NORMALIZED_FILE" 2>/dev/null | wc -l)
  if [ "$NORMALIZED_AUDIO_COUNT" -gt 0 ]; then
    HAS_AUDIO="1"
  else
    HAS_AUDIO=""
  fi
  echo ">>> Normalized file audio streams: $NORMALIZED_AUDIO_COUNT"

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

  cp "$COMPOSE_LOG" "$LOGS_DIR/${SAFE_NAME}_extract_upscale.log" 2>/dev/null

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

  # Distinguish extract failures from upscale failures: check extracted
  # frame count *before* trusting upscale's "0 frames in = 0 frames out,
  # exit 0" success.
  EXTRACTED_COUNT=$(ls "$FRAMES_DIR"/frame*.png 2>/dev/null | wc -l)
  echo ">>> Extracted $EXTRACTED_COUNT source frames."
  if [ "$EXTRACTED_COUNT" -eq 0 ]; then
    ERROR_MSG="Extract produced 0 frames — normalized input may be unreadable or GPU context unavailable."
    echo "ERROR: $ERROR_MSG"
    echo "$ERROR_MSG" > "$LOG_FILE"
    cat "$COMPOSE_LOG" >> "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "$ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # Real-ESRGAN appends _out to output filenames — rename before reassembly.
  echo ">>> Renaming upscaled frames..."
  for f in "$UPSCALED_FRAMES_DIR"/frame*_out.png; do
    [ -f "$f" ] || continue
    base=$(basename "$f" _out.png)
    mv "$f" "$UPSCALED_FRAMES_DIR/${base}.png"
  done

  echo ">>> Verifying upscaled frames..."
  UPSCALED_COUNT=$(ls "$UPSCALED_FRAMES_DIR"/frame*.png 2>/dev/null | wc -l)
  echo ">>> Found $UPSCALED_COUNT upscaled frames."

  if [ "$UPSCALED_COUNT" -eq 0 ]; then
    echo "ERROR: No upscaled frames found after renaming — upscale may have failed silently."
    echo "No upscaled frames found after rename. Extracted $EXTRACTED_COUNT source frames." > "$LOG_FILE"
    cat "$COMPOSE_LOG" >> "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "No upscaled frames found ($EXTRACTED_COUNT extracted)."
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
  cp "$REASSEMBLE_LOG" "$LOGS_DIR/${SAFE_NAME}_reassemble.log" 2>/dev/null

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

  # Host-side belt-and-suspenders check: confirm the output actually landed
  # and isn't a zero-byte file, regardless of what exit code compose reported.
  if [ ! -s "$OUTPUT_DIR/$OUTPUT_FILE" ]; then
    ERROR_MSG="Reassembly reported success but output file is missing or empty: $OUTPUT_DIR/$OUTPUT_FILE"
    echo "ERROR: $ERROR_MSG"
    cat "$COMPOSE_LOG" "$REASSEMBLE_LOG" > "$LOG_FILE"
    echo -e "\n=== REASSEMBLE SUMMARY ===\n$ERROR_MSG" >> "$LOG_FILE"
    update_status "$i" "$FILENAME" "failed" "failed" "$ERROR_MSG"
    set_file_time "$i" "end_time"
    FAILED=$(( FAILED + 1 )); FAILED_FILES+=("$FILENAME")
    rm -f "$FRAMES_DIR"/frame*.png "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # ── Archive + cleanup ───────────────────────────
  # Note: the true original was deleted right after normalization (per config).
  # We archive the normalized intermediate that was actually used for processing.
  echo ">>> Archiving normalized source..."
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
