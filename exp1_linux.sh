#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="$script_dir/data"
bin_dir="$script_dir/bin"
results_dir="$script_dir/results"
work_dir="$results_dir/tmp"

seq_file="$data_dir/achromobacter_xylosoxidans__01.seq"
out_file="$results_dir/exp1_linux.csv"
log_file="$results_dir/exp1_linux.log"

mkdir -p "$results_dir" "$work_dir"
export PATH="$bin_dir:$PATH"

nproc_count="$(nproc)"
export OMP_NUM_THREADS="$nproc_count"

filename="$(basename "$seq_file")"
original_size="$(stat -c%s "$seq_file")"
original_hash="$(sha256sum "$seq_file" | awk '{print $1}')"

: > "$log_file"

cleanup() { rm -rf "$work_dir"; rm -f "$script_dir/of.txt"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Locate compressors
# ---------------------------------------------------------------------------

declare -A tool_candidates=(
    [7zip]="7z"
    [gzip]="gzip"
    [zstd]="zstd"
    [pigz]="pigz"
    [bzip3]="bzip3"
    [bsc]="bsc"
    [mcm]="mcm"
)

declare -A tools
missing=()
for name in "${!tool_candidates[@]}"; do
    for candidate in ${tool_candidates[$name]}; do
        if path="$(command -v "$candidate" 2>/dev/null)"; then
            tools[$name]="$path"
            break
        fi
    done
    [[ -v tools[$name] ]] || missing+=("$name")
done

if (( ${#missing[@]} > 0 )); then
    echo "Missing compressors (not found in bin/ or on PATH): ${missing[*]}" >&2
    exit 1
fi

echo "compressor,level,compressed_size,compression_ratio,compression_time,decompression_time,avg_cpu_compression,avg_cpu_decompression,is_correct" \
    > "$out_file"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_correct() {
    local target_file="$2"
    if [ -f "$target_file" ]; then
        local current_hash
        current_hash="$(sha256sum "$target_file" | awk '{print $1}')"
        if [ "$current_hash" = "$original_hash" ]; then
            echo 1
            return
        fi
    fi
    echo 0
}

log_result() {
    echo "$1,$2,$3,$4,$5,$6,$7,$8,$9" >> "$out_file"
    echo "[$1] level=$2 ratio=$4 correct=${9}"
}

mktmp_dir() {
    mktemp -d "$work_dir/$1.XXXXXX"
}

# Runs "$@", timing it and estimating average CPU utilization from
# /proc/stat samples taken every ~200ms while it's running.
# Prints "elapsed_seconds avg_cpu_percent" to stdout.
timed_run() {
    local samples
    samples="$(mktemp)"

    (
        while :; do
            read -r _ u n s i iw irq sirq st _ < /proc/stat
            echo "$((u + n + s + irq + sirq + st)) $((i + iw))"
            sleep 0.2
        done
    ) > "$samples" &
    local sampler=$!

    sleep 0.3   # let a few samples accumulate before starting the clock
    local start end
    start="$(date +%s.%N)"
    "$@"
    end="$(date +%s.%N)"

    kill "$sampler" 2>/dev/null
    wait "$sampler" 2>/dev/null

    awk -v start="$start" -v end="$end" '
        NR == 1 { first_busy = $1; first_idle = $2; next }
        { last_busy = $1; last_idle = $2 }
        END {
            busy  = last_busy - first_busy
            idle  = last_idle - first_idle
            total = busy + idle
            cpu   = (total > 0) ? (busy / total) * 100 : 0
            printf "%.4f %.2f\n", (end - start), cpu
        }' "$samples"
    rm -f "$samples"
}

#   compress_fn   <level> <archive>
#   decompress_fn <archive> <out_dir>
run_standard_sweep() {
    local name="$1" compress_fn="$2" decompress_fn="$3"
    shift 3
    local levels=("$@")

    for level in "${levels[@]}"; do
        local dir archive out
        dir="$(mktmp_dir "$name")"
        archive="$dir/$filename.$name"
        out="$dir/$filename"

        read -r comp_time comp_cpu < <(timed_run "$compress_fn" "$level" "$archive")
        local comp_size ratio
        comp_size="$(stat -c%s "$archive")"
        ratio="$(awk -v a="$comp_size" -v b="$original_size" 'BEGIN{printf "%.4f", a/b}')"

        read -r decomp_time decomp_cpu < <(timed_run "$decompress_fn" "$archive" "$dir")
        local correct
        correct="$(is_correct "$out")"

        log_result "$name" "$level" "$comp_size" "$ratio" "$comp_time" "$decomp_time" "$comp_cpu" "$decomp_cpu" "$correct"
        rm -rf "$dir"
    done
}

# ---------------------------------------------------------------------------
# Per-tool compress/decompress commands
# ---------------------------------------------------------------------------

sevenzip_compress()   { "${tools[7zip]}" a -mmt=on "-mx=$1" "$2" "$seq_file" >> "$log_file" 2>&1; }
sevenzip_decompress() { "${tools[7zip]}" x -y "$1" "-o$2" >> "$log_file" 2>&1; }

gzip_compress()   { "${tools[gzip]}" "-$1" -c "$seq_file" > "$2"; }
gzip_decompress() { "${tools[gzip]}" -d -c "$1" > "$2/$filename"; }

zstd_compress()   { "${tools[zstd]}" -T0 "-$1" -q -f -o "$2" "$seq_file" >> "$log_file" 2>&1; }
zstd_decompress() { "${tools[zstd]}" -T0 -d -q -f -o "$2/$filename" "$1" >> "$log_file" 2>&1; }

pigz_compress()   { "${tools[pigz]}" "-$1" -c -k "$seq_file" > "$2"; }
pigz_decompress() { "${tools[pigz]}" -d -c "$1" > "$2/$filename"; }

bzip3_compress()   { "${tools[bzip3]}" -j "$nproc_count" "$1" -e -c "$seq_file" > "$2" 2>>"$log_file"; }
bzip3_decompress() { "${tools[bzip3]}" -j "$nproc_count" -d -c "$1" > "$2/$filename" 2>>"$log_file"; }

bsc_compress()   { "${tools[bsc]}" e "$seq_file" "$2" "$1" >> "$log_file" 2>&1; }
bsc_decompress() { "${tools[bsc]}" d "$1" "$2/$filename" >> "$log_file" 2>&1; }

# ---------------------------------------------------------------------------
# mcm - in-place tool: won't take custom in/out paths, so it runs inside its
# own scratch dir on a bare filename.
# ---------------------------------------------------------------------------

mcm_compress()   { "${tools[mcm]}" "$1" "$2" "$3" >> "$log_file" 2>&1; rm -f of.txt; }
mcm_decompress() { "${tools[mcm]}" d "$1" >> "$log_file" 2>&1; rm -f of.txt; }

run_mcm_sweep() {
    local levels=("$@")

    for level in "${levels[@]}"; do
        local dir local_file
        dir="$(mktmp_dir "mcm")"
        local_file="$dir/$filename"
        cp "$seq_file" "$local_file"

        pushd "$dir" > /dev/null

        echo "=== mcm compress level=$level $(date) ===" >> "$log_file"
        read -r comp_time comp_cpu < <(timed_run mcm_compress "$level" "$filename" "$filename.mcm")
        local comp_size ratio
        comp_size="$(stat -c%s "$filename.mcm" 2>/dev/null || echo 0)"
        ratio="$(awk -v a="$comp_size" -v b="$original_size" 'BEGIN{printf "%.4f", a/b}')"

        rm -f "$filename"
        read -r decomp_time decomp_cpu < <(timed_run mcm_decompress "$filename.mcm")

        popd > /dev/null

        local correct
        correct="$(is_correct "$local_file")"
        log_result "mcm" "$level" "$comp_size" "$ratio" "$comp_time" "$decomp_time" "$comp_cpu" "$decomp_cpu" "$correct"
        rm -rf "$dir"
    done
}

# ---------------------------------------------------------------------------
# Sweeps
# ---------------------------------------------------------------------------

run_standard_sweep "7zip" sevenzip_compress sevenzip_decompress 1 2 3 4 5 6 7 8 9
run_standard_sweep "gzip" gzip_compress gzip_decompress 1 2 3 4 5 6 7 8 9
run_standard_sweep "zstd" zstd_compress zstd_decompress 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
run_standard_sweep "pigz" pigz_compress pigz_decompress 1 2 3 4 5 6 7 8 9
run_standard_sweep "bzip3" bzip3_compress bzip3_decompress -b8 -b16 -b32 -b64 -b128 -b256
run_standard_sweep "bsc" bsc_compress bsc_decompress -b10 -b25 -b50 -b100 -b200 -b400 -b800 -b1600 -b2047

run_mcm_sweep -t -f -m -h -x

echo "exp1 complete; results saved to $out_file"