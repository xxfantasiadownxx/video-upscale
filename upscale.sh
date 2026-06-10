#!/bin/bash
# upscale.sh — Batch AI upscale all video files in input/ to 1080p
# Usage: just run ./upscale.sh — no arguments needed
# Folders:
#   original_video_files/  — drop source videos here; originals archived here after processing
#   original_frame_files/  — extracted PNG frames from source
#   upscaled_frame_files/  — Real-ESRGAN upscaled frames (temp)
#   upscaled_video_files/  — final 1080p output videos
# GPU: Optimized for GTX 1660 Ti (6GB VRAM, no Tensor Cores)
#   Model : realesr-general-x4v3  (faster than x4plus, good for video)
#   Tile  : 64 (safe for 6GB; bump to 0 to attempt full-frame if no OOM)
#   Note  : For animation/cel content swap model to realesr-animevideov3

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/original_video_files"
OUTPUT_DIR="$BASE_DIR/upscaled_video_files"
FINISHED_DIR="$BASE_DIR/upscaled_frame_files"
FRAMES_DIR="$BASE_DIR/original_frame_files"

# ─────────────────────────────────────────
# HELPER: PROGRESS BAR (ASCII only)
# Usage: show_progress <done> <total> <start_epoch> <label>
# ─────────────────────────────────────────
show_progress() {
  local done=$1
  local total=$2
  local start=$3
  local label=$4
  local now elapsed eta pct filled empty bar

  now=$(date +%s)
  elapsed=$(( now - start ))
  pct=0
  eta="--:--:--"

  if [ "$total" -gt 0 ]; then
    pct=$(( done * 100 / total ))
    if [ "$done" -gt 0 ]; then
      local est_total=$(( elapsed * total / done ))
      local remaining=$(( est_total - elapsed ))
      [ "$remaining" -lt 0 ] && remaining=0
      eta=$(printf "%02d:%02d:%02d" \
        $(( remaining / 3600 )) \
        $(( (remaining % 3600) / 60 )) \
        $(( remaining % 60 )))
    fi
  fi

  filled=$(( pct * 40 / 100 ))
  empty=$(( 40 - filled ))
  bar=$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')

  local el_fmt
  el_fmt=$(printf "%02d:%02d:%02d" \
    $(( elapsed / 3600 )) \
    $(( (elapsed % 3600) / 60 )) \
    $(( elapsed % 60 )))

  printf "\r  %-12s [%s] %3d%%  elapsed %s  eta %s  (%d/%d)  " \
    "$label" "$bar" "$pct" "$el_fmt" "$eta" "$done" "$total"
}

# ─────────────────────────────────────────
# HELPER: PROCESS ONE FILE
# ─────────────────────────────────────────
process_file() {
  local VIDEO_FILE="$1"
  local ORIGINAL_FILENAME
  local EXTENSION
  local MKV_FILE
  local FPS DURATION_SEC DUR_FMT ESTIMATED_FRAMES EST_UPSCALE_FMT
  local FRAME_COUNT UPSCALED_COUNT OUTPUT_NAME
  local EXTRACT_START UPSCALE_START REASSEMBLE_START

  ORIGINAL_FILENAME=$(basename "$VIDEO_FILE")
  EXTENSION="${ORIGINAL_FILENAME##*.}"

  echo ""
  echo "================================================"
  echo "  Processing : $ORIGINAL_FILENAME"
  echo "================================================"

  # ── Clean up leftover frames ──────────────────────
  echo ">>> Cleaning up any leftover frames from a previous run..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$FINISHED_DIR"/frame*.png

  # ── Convert to MKV if needed ──────────────────────
  local WORK_NAME="${ORIGINAL_FILENAME%.*}.mkv"

  if [[ "${EXTENSION,,}" == "mkv" ]]; then
    echo ">>> Already an MKV, skipping conversion."
    # Rename only if it isn't already named correctly
    if [[ "$ORIGINAL_FILENAME" != "$WORK_NAME" ]]; then
      mv "$VIDEO_FILE" "$INPUT_DIR/$WORK_NAME"
    fi
  else
    echo ">>> Not an MKV ($EXTENSION detected). Converting with ffmpeg (Nvidia)..."

    docker run --gpus all --rm \
      -v "$INPUT_DIR":/original_video_files \
      jrottenberg/ffmpeg:4.4-nvidia \
      -hwaccel cuda \
      -i /original_video_files/"$ORIGINAL_FILENAME" \
      -c:v h264_nvenc \
      -preset p4 \
      -rc vbr \
      -cq 18 \
      -c:a copy \
      /original_video_files/"$WORK_NAME"

    if [ $? -ne 0 ]; then
      echo "ERROR: ffmpeg conversion failed for $ORIGINAL_FILENAME — skipping."
      return 1
    fi

    echo ">>> Conversion successful. Removing original..."
    rm -f "$VIDEO_FILE"
  fi

  MKV_FILE="$INPUT_DIR/$WORK_NAME"

  # ── Probe framerate and duration ─────────────────
  echo ">>> Probing source file..."

  local PROBE
  PROBE=$(docker run --rm \
    --entrypoint ffprobe \
    -v "$INPUT_DIR":/original_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -v error \
    -select_streams v:0 \
    -of default=noprint_wrappers=1:nokey=1 \
    -show_entries stream=r_frame_rate,duration \
    /original_video_files/"$WORK_NAME" 2>/dev/null)

  local RAW_FPS RAW_DUR
  RAW_FPS=$(echo "$PROBE" | grep -E '^[0-9]+/[0-9]+$' | head -n 1)
  RAW_DUR=$(echo "$PROBE" | grep -E '^[0-9]+\.' | head -n 1)

  FPS=$(echo "$RAW_FPS" | awk -F'/' '{printf "%.3f", $1/$2}')
  FPS=${FPS:-29.97}

  DURATION_SEC=$(echo "$RAW_DUR" | awk '{printf "%d", $1}')
  DURATION_SEC=${DURATION_SEC:-0}

  DUR_FMT=$(printf "%02d:%02d:%02d" \
    $(( DURATION_SEC / 3600 )) \
    $(( (DURATION_SEC % 3600) / 60 )) \
    $(( DURATION_SEC % 60 )))

  ESTIMATED_FRAMES=$(echo "$FPS $DURATION_SEC" | awk '{printf "%d", $1 * $2}')

  local EST_UPSCALE_SEC=$ESTIMATED_FRAMES
  EST_UPSCALE_FMT=$(printf "%02d:%02d:%02d" \
    $(( EST_UPSCALE_SEC / 3600 )) \
    $(( (EST_UPSCALE_SEC % 3600) / 60 )) \
    $(( EST_UPSCALE_SEC % 60 )))

  echo ">>> Framerate  : $FPS fps"
  echo ">>> Duration   : $DUR_FMT ($DURATION_SEC seconds)"
  echo ">>> Est. frames: ~$ESTIMATED_FRAMES"
  echo ">>> Est. upscale time: ~$EST_UPSCALE_FMT  (based on ~1 fps on GTX 1660 Ti)"

  mkdir -p "$FRAMES_DIR" "$FINISHED_DIR" "$OUTPUT_DIR"

  # ── Extract frames ────────────────────────────────
  echo ">>> Extracting frames..."
  EXTRACT_START=$(date +%s)

  docker run --gpus all --rm \
    -v "$INPUT_DIR":/original_video_files \
    -v "$FRAMES_DIR":/original_frame_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -hwaccel cuda \
    -i /original_video_files/"$WORK_NAME" \
    /original_frame_files/frame%08d.png &

  local FFMPEG_PID=$!
  while kill -0 $FFMPEG_PID 2>/dev/null; do
    local DONE=$(ls "$FRAMES_DIR"/*.png 2>/dev/null | wc -l)
    show_progress "$DONE" "$ESTIMATED_FRAMES" "$EXTRACT_START" "Extracting"
    sleep 1
  done
  wait $FFMPEG_PID
  local EXTRACT_EXIT=$?
  echo

  if [ $EXTRACT_EXIT -ne 0 ]; then
    echo "ERROR: Frame extraction failed for $ORIGINAL_FILENAME — skipping."
    rm -f "$FRAMES_DIR"/frame*.png
    return 1
  fi

  FRAME_COUNT=$(ls "$FRAMES_DIR"/*.png 2>/dev/null | wc -l)
  echo ">>> Extracted $FRAME_COUNT frames."

  # ── AI upscale frames ─────────────────────────────
  echo ">>> Starting AI upscale..."
  UPSCALE_START=$(date +%s)

  docker run --gpus all --rm \
    -v "$FRAMES_DIR":/original_frame_files \
    -v "$FINISHED_DIR":/upscaled_frame_files \
    ghcr.io/ralphv/realesrgan-with-models \
    -n realesr-general-x4v3 \
    -i /original_frame_files \
    -o /upscaled_frame_files \
    --ext png \
    --tile 64 \
    --tile_pad 10 &

  local ESRGAN_PID=$!
  while kill -0 $ESRGAN_PID 2>/dev/null; do
    local DONE=$(ls "$FINISHED_DIR"/*.png 2>/dev/null | wc -l)
    show_progress "$DONE" "$FRAME_COUNT" "$UPSCALE_START" "Upscaling"
    sleep 2
  done
  wait $ESRGAN_PID
  local ESRGAN_EXIT=$?
  echo

  if [ $ESRGAN_EXIT -ne 0 ]; then
    echo "ERROR: Upscaling failed (exit $ESRGAN_EXIT) for $ORIGINAL_FILENAME — skipping."
    rm -f "$FRAMES_DIR"/frame*.png "$FINISHED_DIR"/frame*.png
    return 1
  fi

  UPSCALED_COUNT=$(ls "$FINISHED_DIR"/*.png 2>/dev/null | wc -l)
  if [ "$UPSCALED_COUNT" -eq 0 ]; then
    echo "ERROR: Upscaling produced no output frames for $ORIGINAL_FILENAME — skipping."
    return 1
  fi

  local FIRST_FRAME FRAME_SIZE
  FIRST_FRAME=$(ls "$FINISHED_DIR"/*.png 2>/dev/null | head -n 1)
  FRAME_SIZE=$(stat -c '%s' "$FIRST_FRAME")
  if [ "$FRAME_SIZE" -lt 10000 ]; then
    echo "ERROR: Output frames appear corrupt (first frame ${FRAME_SIZE} bytes) — skipping."
    echo "       Try reducing --tile below 64 if this is an OOM issue."
    rm -f "$FRAMES_DIR"/frame*.png "$FINISHED_DIR"/frame*.png
    return 1
  fi

  echo ">>> Upscaling complete. $UPSCALED_COUNT frames written (first frame ${FRAME_SIZE} bytes -- looks good)."

  # ── Rename frames for ffmpeg ──────────────────────
  echo ">>> Renaming frames for ffmpeg compatibility..."
  local COUNT=1
  for F in $(ls "$FINISHED_DIR"/frame*.png 2>/dev/null | sort); do
    local NEW
    NEW=$(printf "$FINISHED_DIR/frame%08d.png" $COUNT)
    mv "$F" "$NEW"
    COUNT=$(( COUNT + 1 ))
  done
  echo ">>> Renamed $UPSCALED_COUNT frames."

  # ── Reassemble video ──────────────────────────────
  OUTPUT_NAME="${ORIGINAL_FILENAME%.*}_upscaled_1080p.mkv"
  echo ">>> Reassembling as $OUTPUT_NAME (1080p)..."
  REASSEMBLE_START=$(date +%s)

  docker run --gpus all --rm \
    -v "$FINISHED_DIR":/upscaled_frame_files \
    -v "$INPUT_DIR":/original_video_files \
    -v "$OUTPUT_DIR":/upscaled_video_files \
    jrottenberg/ffmpeg:4.4-nvidia \
    -framerate "$FPS" \
    -i /upscaled_frame_files/frame%08d.png \
    -i /original_video_files/"$WORK_NAME" \
    -map 0:v \
    -map 1:a \
    -vf scale=-2:1080 \
    -r "$FPS" \
    -c:v h264_nvenc \
    -preset p4 \
    -rc vbr \
    -cq 18 \
    -c:a copy \
    -vsync cfr \
    /upscaled_video_files/"$OUTPUT_NAME" &

  local REASSEMBLE_PID=$!
  while kill -0 $REASSEMBLE_PID 2>/dev/null; do
    local elapsed=$(( $(date +%s) - REASSEMBLE_START ))
    local el_fmt
    el_fmt=$(printf "%02d:%02d:%02d" \
      $(( elapsed / 3600 )) \
      $(( (elapsed % 3600) / 60 )) \
      $(( elapsed % 60 )))
    printf "\r  Reassembling ... elapsed %s  " "$el_fmt"
    sleep 2
  done
  wait $REASSEMBLE_PID
  local REASSEMBLE_EXIT=$?
  echo

  if [ $REASSEMBLE_EXIT -ne 0 ]; then
    echo "ERROR: Reassembly failed for $ORIGINAL_FILENAME."
    rm -f "$FRAMES_DIR"/frame*.png "$FINISHED_DIR"/frame*.png
    return 1
  fi

  # ── Archive original, clean up frames ────────────
  echo ">>> Moving original to original_video_files/..."
  mv "$MKV_FILE" "$INPUT_DIR/${WORK_NAME%.*}_original.mkv"

  echo ">>> Cleaning up frames..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$FINISHED_DIR"/frame*.png

  local TOTAL_ELAPSED=$(( $(date +%s) - EXTRACT_START ))
  local TOTAL_FMT
  TOTAL_FMT=$(printf "%02d:%02d:%02d" \
    $(( TOTAL_ELAPSED / 3600 )) \
    $(( (TOTAL_ELAPSED % 3600) / 60 )) \
    $(( TOTAL_ELAPSED % 60 )))

  echo ""
  echo "  Done : $OUTPUT_DIR/$OUTPUT_NAME"
  echo "  Time : $TOTAL_FMT"

  return 0
}

# ─────────────────────────────────────────
# MAIN: FIND ALL VIDEO FILES, SORT, LOOP
# ─────────────────────────────────────────
mkdir -p "$FRAMES_DIR" "$FINISHED_DIR" "$OUTPUT_DIR"

echo ">>> Scanning $INPUT_DIR for video files..."

mapfile -d '' VIDEO_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f \( \
    -iname "*.mkv" -o \
    -iname "*.mp4" -o \
    -iname "*.avi" -o \
    -iname "*.mov" -o \
    -iname "*.ts"  -o \
    -iname "*.m2ts" -o \
    -iname "*.mpg" -o \
    -iname "*.mpeg" -o \
    -iname "*.wmv" \
  \) -print0 | sort -z)

TOTAL_FILES=${#VIDEO_FILES[@]}

if [ "$TOTAL_FILES" -eq 0 ]; then
  echo "ERROR: No video files found in $INPUT_DIR"
  exit 1
fi

echo ">>> Found $TOTAL_FILES file(s) to process."

BATCH_START=$(date +%s)
SUCCEEDED=0
FAILED=0
FAILED_FILES=()

for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[$i]}"
  FILE_NUM=$(( i + 1 ))
  echo ""
  echo ">>> File $FILE_NUM of $TOTAL_FILES : $(basename "$FILE")"

  if process_file "$FILE"; then
    SUCCEEDED=$(( SUCCEEDED + 1 ))
  else
    FAILED=$(( FAILED + 1 ))
    FAILED_FILES+=("$(basename "$FILE")")
  fi
done

BATCH_ELAPSED=$(( $(date +%s) - BATCH_START ))
BATCH_FMT=$(printf "%02d:%02d:%02d" \
  $(( BATCH_ELAPSED / 3600 )) \
  $(( (BATCH_ELAPSED % 3600) / 60 )) \
  $(( BATCH_ELAPSED % 60 )))

echo ""
echo "================================================"
echo "  Batch complete!"
echo "  Processed  : $TOTAL_FILES file(s)"
echo "  Succeeded  : $SUCCEEDED"
echo "  Failed     : $FAILED"
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "  Failed files:"
  for F in "${FAILED_FILES[@]}"; do
    echo "    - $F"
  done
fi
echo "  Total time : $BATCH_FMT"
echo "  Output dir : $OUTPUT_DIR"
echo "================================================"
