#!/bin/bash
# run.sh — Loop through all video files in original_video_files/ and process
#           each one via docker compose, one at a time, alphabetically.
# Usage: ./run.sh

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$BASE_DIR/original_video_files"
FRAMES_DIR="$BASE_DIR/original_frame_files"
UPSCALED_FRAMES_DIR="$BASE_DIR/upscaled_frame_files"
OUTPUT_DIR="$BASE_DIR/upscaled_video_files"

mkdir -p "$INPUT_DIR" "$FRAMES_DIR" "$UPSCALED_FRAMES_DIR" "$OUTPUT_DIR"

# ── Find all video files, sorted alphabetically ──
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
  FILENAME=$(basename "$FILE")
  FILE_NUM=$(( i + 1 ))

  echo ""
  echo "================================================"
  echo "  File $FILE_NUM of $TOTAL_FILES : $FILENAME"
  echo "================================================"

  # Clean up any leftover frames from a previous run
  echo ">>> Cleaning up leftover frames..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$UPSCALED_FRAMES_DIR"/frame*.png

  # Run the full pipeline via docker compose, passing filename as env var
  echo ">>> Starting docker compose pipeline..."
  EPISODE_FILE="$FILENAME" docker compose --project-directory "$BASE_DIR" up --abort-on-container-failure

  COMPOSE_EXIT=$?

  # Tear down containers ready for next file
  docker compose --project-directory "$BASE_DIR" down

  if [ $COMPOSE_EXIT -ne 0 ]; then
    echo "ERROR: Pipeline failed for $FILENAME"
    FAILED=$(( FAILED + 1 ))
    FAILED_FILES+=("$FILENAME")
    # Clean up frames so next file starts fresh
    rm -f "$FRAMES_DIR"/frame*.png
    rm -f "$UPSCALED_FRAMES_DIR"/frame*.png
    continue
  fi

  # Archive the original into original_video_files/ with a suffix so it
  # won't be picked up again on a re-run
  echo ">>> Archiving original..."
  mv "$FILE" "$INPUT_DIR/${FILENAME%.*}_original.${FILENAME##*.}"

  # Clean up frames
  echo ">>> Cleaning up frames..."
  rm -f "$FRAMES_DIR"/frame*.png
  rm -f "$UPSCALED_FRAMES_DIR"/frame*.png

  SUCCEEDED=$(( SUCCEEDED + 1 ))
  echo ">>> Done : $FILENAME"
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
