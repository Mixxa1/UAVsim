#!/bin/bash
# Builds the runtime audio pack from the downloaded CC0 source recordings.
#
# The sources are studio-length stereo files — 24-bit, 44.1/48 kHz, and in one case seven
# minutes long. None of that is what the simulation plays. The runtime wants short mono
# clips at one sample rate, because:
#
#   * spatialisation is mono-only. `AVAudioEnvironmentNode` (and `SCNAudioSource` above it)
#     pans a *point* source; hand it a stereo file and it either refuses to spatialise or
#     folds the channels down itself. Every positional sound in this pack is therefore mono
#     by construction, not by accident;
#   * one sample rate means no per-voice resampling in the render callback;
#   * 16-bit PCM rather than AAC because several of these are loops. An encoder adds priming
#     and padding frames, and a loop with padding clicks once per revolution.
#
# Levels are peak-normalised, deliberately NOT loudness-normalised. Loudness normalisation
# would make a snapping twig and a wing hitting a wall come out the same size, which is the
# exact distinction the impact resolver exists to draw. The pack carries a `defaultGainDb`
# per asset instead, so relative loudness is a stated design decision rather than an
# accident of how each contributor recorded their sample.
#
# Sources live in `.audio-sources/` (gitignored). Downloads the pack does not reference are
# kept in `.audio-sources/unused/` — the script only looks in the top level, so anything moved
# there stops being built without being lost. Reinstating one is a `mv` and a table row.
#
# Usage:  Tools/audio-pack.sh [--sources DIR] [--out DIR]
# Requires ffmpeg (brew install ffmpeg).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/.audio-sources"
OUT="$ROOT/DroneUAVDemo/Resources/Audio"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sources) SOURCES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "audio-pack: ffmpeg not found. brew install ffmpeg" >&2
  exit 1
fi

SAMPLE_RATE=48000
PEAK_DBFS=-3.0
FADE=0.008          # 8 ms edge fades — kills the click a hard cut leaves, too short to hear.

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Asset table — the single source of truth for what the pack contains.
#
# id | category | subdirectory | source file | mode | parameters | defaultGainDb
#
# The source field may be a glob, and for `slice` it may be a comma-separated list of them.
# Freesound's filenames carry a slug after the numeric id and the slug is not something to
# depend on, so `488589__*` is both shorter and safer than transcribing whatever the download
# happened to be called. Slicing across several sources is how one id gets variants that are
# genuinely different recordings rather than four cuts of the same one.
#
# modes:
#   oneshot START DUR    one clip, from START for DUR seconds
#   slice   N MIN MAX    auto-split on silence, keep up to N segments as id_1..id_N
#   loop    START LEN X  window of LEN seconds from START, crossfaded over X so it repeats
#                        without a seam
#   pitched START DUR R  one clip played at rate R — below 1 it is slower *and* lower, which
#                        is what a bigger, heavier machine sounds like
# ---------------------------------------------------------------------------
read -r -d '' ASSETS <<'TABLE' || true
fpv_electronics_boot|vehicle|Vehicle/Electric|854647__qubodup__uav-drone-bootconnection-sounds.wav|oneshot|0.00 5.20|-6.0
uav_heavy_spinup|vehicle|Vehicle/Electric|329543__*|pitched|1.20 5.60 0.80|-6.0
helicopter_rotor_loop|vehicle|Vehicle/Rotorcraft|187681__*|loop|0.30 5.00 0.35|-7.0
fpv_spinup|vehicle|Vehicle/Electric|741030__*|oneshot|0.00 1.41|-6.0
fixedwing_electric_motor|vehicle|Vehicle/Electric|418013__*|loop|0.50 4.50 0.30|-10.0
fixedwing_propeller_loop|vehicle|Vehicle/Electric|457013__*|loop|2.00 6.00 0.35|-9.0
airflow_loop|aero|Aero/Airflow|20108__*|loop|2.00 6.00 0.35|-6.0
uav_small_spinup|vehicle|Vehicle/Electric|683299__sadiquecat__dji-mavic-mini-2-propeller-start-up-no-takeoff-close-take.wav|oneshot|1.20 4.50|-8.0
uav_small_hover|vehicle|Vehicle/Electric|683298__sadiquecat__dji-mavic-mini-2-hover-above-ground-up-down-xy-mic-placement-zoom-h5.wav|loop|8.00 6.00 0.35|-9.0
uav_heavy_hover_loop|vehicle|Vehicle/Electric|854382__qubodup__big-slow-heavy-drone-hovering-idle-loop.wav|loop|0.40 6.00 0.35|-8.0
uav_hex_flight|vehicle|Vehicle/Electric|264853__torror__hexacopter-drone-flight.wav|loop|18.00 6.00 0.35|-9.0
fpv_flight_loop|vehicle|Vehicle/Electric|854466__qubodup__fpv-drone-flight-3.wav|loop|3.00 5.00 0.30|-8.0
impact_mechanical_short|impact|Impact/Metal|332056__qubodup__fast-collision.flac|oneshot|0.00 0.30|-4.0
impact_metal_heavy|impact|Impact/Metal|422438__behansean__metallic-crash.wav|oneshot|0.00 2.20|-2.0
concrete_hit|impact|Impact/Concrete|321477__dslrguide__concrete-hit.wav|oneshot|0.00 0.95|-3.0
scrape_metal_concrete|impact|Impact/Concrete|488901__rvgerxini__metal-scrape-on-concrete.mp3|loop|0.30 1.80 0.25|-10.0
tree_trunk_impact|impact|Impact/Wood|550918__profispiesser__fxsasc-wood-tree-trunk-impact-ground-forest-5-variants.wav|slice|5 0.40 3.00|-4.0
foliage_branch_impact|impact|Impact/Wood|651319__shatterstars__branch-impact.wav|slice|5 0.30 2.00|-12.0
ground_dirt_thud|impact|Impact/Dirt|640204__7of9designs__heavy-metal-thud-on-ground.mp3|oneshot|0.00 0.78|-5.0
glass_shatter|impact|Impact/Glass|203375__c_rogers__glass-shattering_01.ogg|oneshot|0.00 1.40|-3.0
water_impact|impact|Impact/Water|442773__qubodup__big-water-splash.wav|oneshot|0.00 2.15|-4.0
tree_wood_crack|damage|Damage/Crack|183453__utsuru__wood-crack-1.wav|oneshot|0.00 1.60|-6.0
building_debris|damage|Damage/Debris|703248__xkeril__fall-debris-crash.wav|oneshot|0.00 3.90|-6.0
damage_metal_bend|damage|Damage/Bend|488589__*|oneshot|0.00 1.43|-5.0
damage_stone_crash|damage|Damage/Debris|711657__*|oneshot|0.00 2.50|-4.0
damage_composite_break|damage|Damage/Crack|768318__*|oneshot|0.00 2.45|-5.0
piston_engine_loop|vehicle|Vehicle/Piston|789390__*|loop|0.40 4.00 0.30|-8.0
piston_engine_start|vehicle|Vehicle/Piston|568127__*|oneshot|1.20 8.00|-6.0
turboprop_loop|vehicle|Vehicle/Turboprop|457131__*|loop|100.00 6.00 0.35|-8.0
turboprop_start|vehicle|Vehicle/Turboprop|704945__*|oneshot|9.00 14.00|-7.0
turbojet_loop|vehicle|Vehicle/Turbojet|205581__*|loop|10.00 6.00 0.35|-7.0
turbojet_start|vehicle|Vehicle/Turbojet|704945__*|oneshot|12.00 10.00|-7.0
mechanism_servo|vehicle|Vehicle/Mechanism|824121__*,520514__*,322021__*|slice|6 0.15 1.20|-16.0
TABLE

# Windows above are chosen from measured level profiles rather than guessed:
#   789390 sits flat at −17 dB for its whole length, so any window loops;
#   205581 settles by 2 s and holds −8…−10 dB, so the window starts at 10 s;
#   457131 is 146 s of taxi and take-off — quiet until 3 s, taxi to about 100 s, then power
#     coming up; the window sits in the settled stretch;
#   704945 is silent until 9.5 s, spools to a peak around 17 s and decays after 105 s;
#   20108 is dead flat at −13.5 dB for all 20 s, which is what an airflow bed needs;
#   418013 holds −36 dB for its first 8 s and then winds down, so the window stops at 5 s;
#   457013 is flat at −13.5 dB throughout — a steady propeller rather than a pass;
#   187681 holds −21…−22 dB across its six seconds — already a rotor loop by intent;
#   329543 rises out of the noise at 1.2 s and holds through 10 s, so the spin-up window
#     starts there; at 0.8x it comes out seven seconds long, which is a launch rather
#     than a chirp.
#
# The propeller layer is 457013 and not the flyover (71692) that was suggested for it. A
# flyover recording has the approach and the recession baked in: its level swings 40 dB across
# the pass and the pitch sweeps with the aircraft's own Doppler. Looped, it repeats that pass
# every few seconds, and the simulation then applies its *own* Doppler on top of the recorded
# one. 71692 remains the better source for a fly-by one-shot, which nothing plays yet.
# The turboprop and turbojet starts come from that one recording at different windows. It is
# a compromise and named as one: a turboprop start carries its propeller and a small turbojet
# does not, and no separate CC0 recording of either has been chosen yet.

# Assets the plan asks for that this project cannot supply yet. Recorded in the manifest so
# the runtime can say "not in the pack" instead of silently mapping something else onto them.
#
# Empty, and that is the current state rather than a disabled feature: every id the code can
# ask for, the pack supplies. Three entries lived here and were resolved rather than filled —
# the fly-by bank because a propulsion loop with Doppler already is a fly-by, the plastic
# shell because a moulded polymer cracking is the composite break at a higher pitch, and the
# metal creak because it needs a mechanic this project does not have: a creak is a structure
# under *held* load, and the damage model reports discrete events.
read -r -d '' MISSING <<'TABLE' || true
TABLE

# ---------------------------------------------------------------------------

mono() {  # mono FILE_IN FILE_OUT [extra filters]
  local input="$1" output="$2" filters="${3:-}"
  local chain="aresample=$SAMPLE_RATE,aformat=channel_layouts=mono"
  [[ -n "$filters" ]] && chain="$chain,$filters"
  ffmpeg -hide_banner -loglevel error -y -i "$input" -af "$chain" -c:a pcm_s16le "$output"
}

peak_normalise() {  # peak_normalise FILE — in place, to PEAK_DBFS
  local file="$1"
  local peak
  peak="$(ffmpeg -hide_banner -i "$file" -af volumedetect -f null - 2>&1 |
    awk -F': ' '/max_volume/ {print $2}' | tr -d ' dB')"
  [[ -z "$peak" ]] && return 0
  local gain
  gain="$(awk -v p="$peak" -v t="$PEAK_DBFS" 'BEGIN { printf "%.3f", t - p }')"
  ffmpeg -hide_banner -loglevel error -y -i "$file" -af "volume=${gain}dB" \
    -c:a pcm_s16le "$file.norm.wav"
  mv "$file.norm.wav" "$file"
}

duration_of() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

emit_oneshot() {  # emit_oneshot SRC DST START DUR
  local src="$1" dst="$2" start="$3" dur="$4"
  local fadeOut
  fadeOut="$(awk -v d="$dur" -v f="$FADE" 'BEGIN { printf "%.4f", d - f }')"
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$dur" -i "$src" \
    -af "aresample=$SAMPLE_RATE,aformat=channel_layouts=mono,afade=t=in:st=0:d=$FADE,afade=t=out:st=$fadeOut:d=$FADE" \
    -c:a pcm_s16le "$dst"
  peak_normalise "$dst"
}

# Slows (or speeds) a clip by resampling. Rate and pitch move together, which is the honest
# transform: a larger rotor is both slower and lower, and separating the two — holding pitch
# while stretching time — is a studio effect rather than a physical one.
emit_pitched() {  # emit_pitched SRC DST START DUR RATE
  local src="$1" dst="$2" start="$3" dur="$4" rate="$5"
  local outDur
  outDur="$(awk -v d="$dur" -v r="$rate" 'BEGIN { printf "%.4f", d / r }')"
  local fadeOut
  fadeOut="$(awk -v d="$outDur" -v f="$FADE" 'BEGIN { printf "%.4f", d - f }')"
  local newRate
  newRate="$(awk -v sr="$SAMPLE_RATE" -v r="$rate" 'BEGIN { printf "%d", sr * r }')"
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$dur" -i "$src" \
    -af "aresample=$SAMPLE_RATE,aformat=channel_layouts=mono,asetrate=$newRate,aresample=$SAMPLE_RATE,afade=t=in:st=0:d=$FADE,afade=t=out:st=$fadeOut:d=$FADE" \
    -c:a pcm_s16le "$dst"
  peak_normalise "$dst"
}

# A loop has to arrive back at its own first sample. The window is taken LEN + X long; the
# extra X seconds — the material that *would* have played next — is faded into the first X
# seconds of the clip, so the end of the loop and its beginning are the same signal and the
# repeat is inaudible.
emit_loop() {  # emit_loop SRC DST START LEN XFADE
  local src="$1" dst="$2" start="$3" len="$4" xfade="$5"
  local tailStart
  tailStart="$(awk -v s="$start" -v l="$len" 'BEGIN { printf "%.4f", s + l }')"
  local bodyStart
  bodyStart="$(awk -v s="$start" -v x="$xfade" 'BEGIN { printf "%.4f", s + x }')"
  local bodyLen
  bodyLen="$(awk -v l="$len" -v x="$xfade" 'BEGIN { printf "%.4f", l - x }')"

  mono "$src" "$TMP/head.wav" "atrim=start=$start:duration=$xfade,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=$xfade"
  mono "$src" "$TMP/tail.wav" "atrim=start=$tailStart:duration=$xfade,asetpts=PTS-STARTPTS,afade=t=out:st=0:d=$xfade"
  mono "$src" "$TMP/body.wav" "atrim=start=$bodyStart:duration=$bodyLen,asetpts=PTS-STARTPTS"

  ffmpeg -hide_banner -loglevel error -y -i "$TMP/head.wav" -i "$TMP/tail.wav" \
    -filter_complex "[0:a][1:a]amix=inputs=2:normalize=0[m]" -map "[m]" \
    -c:a pcm_s16le "$TMP/seam.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$TMP/seam.wav" -i "$TMP/body.wav" \
    -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[o]" -map "[o]" \
    -c:a pcm_s16le "$dst"
  peak_normalise "$dst"
}

# Splits a multi-take recording on its own silences. Contributors record five swings of a
# log or twenty snapping branches into one file; those are variants, and variants are what
# stop a repeated contact sounding like a machine gun.
emit_slices() {  # emit_slices SRC DST_DIR ID COUNT MIN MAX START_INDEX -> echoes total written
  local src="$1" dir="$2" id="$3" count="$4" minDur="$5" maxDur="$6" startIndex="${7:-0}"
  mono "$src" "$TMP/full.wav"
  local total
  total="$(duration_of "$TMP/full.wav")"

  # silencedetect gives the gaps; the segments are what lies between them.
  ffmpeg -hide_banner -i "$TMP/full.wav" -af "silencedetect=noise=-42dB:d=0.25" -f null - 2>&1 |
    awk '/silence_start/ { print "S", $NF } /silence_end/ { print "E", $4 }' > "$TMP/marks.txt"

  awk -v total="$total" '
    BEGIN { open = 0; start = 0 }
    $1 == "E" { start = $2; open = 1 }
    $1 == "S" { if (open) { print start, $2; open = 0 } else { if ($2 > 0) print 0, $2 } }
    END { if (open && total > start) print start, total }
  ' "$TMP/marks.txt" > "$TMP/segments.txt"

  local written=$startIndex
  while read -r segStart segEnd; do
    [[ -z "${segStart:-}" ]] && continue
    local segDur
    segDur="$(awk -v a="$segStart" -v b="$segEnd" 'BEGIN { printf "%.4f", b - a }')"
    awk -v d="$segDur" -v lo="$minDur" 'BEGIN { exit !(d >= lo) }' || continue
    # A little pre-roll keeps the transient's very first sample, which silencedetect trims.
    local clipStart clipDur
    clipStart="$(awk -v s="$segStart" 'BEGIN { v = s - 0.02; printf "%.4f", (v > 0 ? v : 0) }')"
    clipDur="$(awk -v d="$segDur" -v hi="$maxDur" 'BEGIN { printf "%.4f", (d + 0.14 < hi ? d + 0.14 : hi) }')"
    written=$((written + 1))
    emit_oneshot "$TMP/full.wav" "$dir/${id}_${written}.wav" "$clipStart" "$clipDur"
    [[ $written -ge $count ]] && break
  done < "$TMP/segments.txt"

  echo "$written"
}

# ---------------------------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"

MANIFEST="$OUT/AudioPack.json"
{
  echo '{'
  echo '  "schemaVersion": 1,'
  echo "  \"sampleRate\": $SAMPLE_RATE,"
  echo '  "channels": 1,'
  echo '  "assets": ['
} > "$MANIFEST"

first=1
missingSources=()

while IFS='|' read -r id category subdir sourceFile mode params gainDb; do
  [[ -z "${id:-}" ]] && continue
  # Globs allowed, comma-separated for slice — see the note on the asset table.
  IFS=',' read -r -a sourcePatterns <<< "$sourceFile"
  resolvedSources=()
  for pattern in "${sourcePatterns[@]}"; do
    candidate="$(compgen -G "$SOURCES/$pattern" | head -1 || true)"
    [[ -n "$candidate" && -f "$candidate" ]] && resolvedSources+=("$candidate")
  done
  if [[ ${#resolvedSources[@]} -eq 0 ]]; then
    missingSources+=("$id ($sourceFile)")
    continue
  fi
  src="${resolvedSources[0]}"
  dir="$OUT/$subdir"
  mkdir -p "$dir"

  variants=1
  isLoop=false
  case "$mode" in
    oneshot)
      read -r start dur <<< "$params"
      emit_oneshot "$src" "$dir/$id.wav" "$start" "$dur"
      ;;
    loop)
      read -r start len xfade <<< "$params"
      emit_loop "$src" "$dir/$id.wav" "$start" "$len" "$xfade"
      isLoop=true
      ;;
    slice)
      read -r count minDur maxDur <<< "$params"
      # Each listed source contributes variants until the count is reached, so a bank can be
      # built from several independent recordings rather than several cuts of one.
      variants=0
      for source in "${resolvedSources[@]}"; do
        [[ "$variants" -ge "$count" ]] && break
        variants="$(emit_slices "$source" "$dir" "$id" "$count" "$minDur" "$maxDur" "$variants")"
      done
      if [[ "$variants" -eq 0 ]]; then
        echo "audio-pack: $id produced no slices from $sourceFile" >&2
        continue
      fi
      ;;
    pitched)
      read -r start dur rate <<< "$params"
      emit_pitched "$src" "$dir/$id.wav" "$start" "$dur" "$rate"
      ;;
    *)
      echo "audio-pack: unknown mode '$mode' for $id" >&2
      exit 1
      ;;
  esac

  if [[ "$variants" -gt 1 || "$mode" == "slice" ]]; then
    duration="$(duration_of "$dir/${id}_1.wav")"
    relative="$subdir/$id"
  else
    duration="$(duration_of "$dir/$id.wav")"
    relative="$subdir/$id"
  fi

  [[ $first -eq 0 ]] && echo ',' >> "$MANIFEST"
  first=0
  printf '    { "id": "%s", "category": "%s", "path": "%s", "variants": %s, "loop": %s, "durationSeconds": %.3f, "defaultGainDb": %s }' \
    "$id" "$category" "$relative" "$variants" "$isLoop" "$duration" "$gainDb" >> "$MANIFEST"
  echo "  packed $id ($variants variant(s), ${duration}s)"
done <<< "$ASSETS"

{
  echo
  echo '  ],'
  echo '  "unavailable": ['
} >> "$MANIFEST"

firstMissing=1
while IFS='|' read -r id category note; do
  [[ -z "${id:-}" ]] && continue
  [[ $firstMissing -eq 0 ]] && echo ',' >> "$MANIFEST"
  firstMissing=0
  printf '    { "id": "%s", "category": "%s", "reason": "%s" }' "$id" "$category" "$note" >> "$MANIFEST"
done <<< "$MISSING"

{
  echo
  echo '  ]'
  echo '}'
} >> "$MANIFEST"

echo
if [[ ${#missingSources[@]} -gt 0 ]]; then
  echo "audio-pack: source file absent for:"
  printf '  - %s\n' "${missingSources[@]}"
fi
echo "audio-pack: wrote $(find "$OUT" -name '*.wav' | wc -l | tr -d ' ') clips to $OUT"
du -sh "$OUT"
