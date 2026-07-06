#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="$script_dir/data"
bin_dir="$script_dir/bin"
results_dir="$script_dir/results"
work_dir="$results_dir/tmp"

out_file="$results_dir/exp2_linux.csv"
log_file="$results_dir/exp2_linux.log"

mkdir -p "$results_dir" "$work_dir"
export PATH="$bin_dir:$PATH"

nproc_count="$(nproc)"
export OMP_NUM_THREADS="$nproc_count"

cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Locate compressors - only the ones needed for the exp1 winners
# ---------------------------------------------------------------------------

declare -A tool_candidates=(
    [7zip]="7z"
    [zstd]="zstd"
    [bzip3]="bzip3"
    [bsc]="bsc"
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

# ---------------------------------------------------------------------------
# Hardcoded sha256 of every original .seq file. 
# Avoids re-reading the (often huge) original file on every correctness check:
# we only ever hash the decompressed output and compare against these.
# ---------------------------------------------------------------------------

declare -A file_hashes=(
    [achromobacter_xylosoxidans__01_1_16.seq]="293a5423d5280b191d1ee6928e8893f7bacaaad782f5f83c27061e594bdc5d82"
    [achromobacter_xylosoxidans__01_1_4.seq]="32c0fd59566c989bcd2f820b94df68bab3ba749f62dafa26fd585b1e9425c8d3"
    [achromobacter_xylosoxidans__01_1_64.seq]="4b28dad96791dfa7655b1af06c4bceff703dcc33fecf729198d5e779fab3cdcb"
    [achromobacter_xylosoxidans__01.seq]="f65d1b661c0cb437de690f0fdb89d03f882ce7e829c68a29e69a908c84513f38"
    [escherichia_coli__01_1_16.seq]="199ef9eb0f64dbd1c93abab37dadb6d0aff9e88d39d473ac6bf02b874fc90737"
    [escherichia_coli__01_1_4.seq]="6d2bca82447989b99a29bcb610b8f8ed596bfde199c2db34fb95715134d0da7e"
    [escherichia_coli__01_1_64.seq]="80e80a0ad4237e19aa551c085cc7bb3fde3ee0645588e22dc6a8d10eae31c4c3"
    [escherichia_coli__01.seq]="7435e521b5042fd6844ddc790bbbd616e270c046155ca3208d2edfdfdb07d5ed"
    [listeria_monocytogenes__01_1_16.seq]="bf7782415bdd11cbf84ef9aa845f03b9bed471dbffe3a67a11ec39b9834707b8"
    [listeria_monocytogenes__01_1_4.seq]="c50bd24d356f0064b511c0d566fae303ef0129419da1996a42b1f057c50a125d"
    [listeria_monocytogenes__01_1_64.seq]="4ca84b4e518124f0bfdd4bc684d97e09a82f17d8e4027b14b93a7ace53550ef7"
    [listeria_monocytogenes__01.seq]="c4e569403b4f7fd540dbaee2ccd318965e4a96b9475fd1fccdd4713d18ff7ca2"
    [mycobacterium_tuberculosis__01_1_16.seq]="8293d20bfb16dedce7f73aa75514451f16acaa2f138800507822e66cfa698847"
    [mycobacterium_tuberculosis__01_1_4.seq]="aa966350dd3ef8334231ec645ec905e01ebeb122ac02359d790b06d761f45785"
    [mycobacterium_tuberculosis__01_1_64.seq]="79c5f217b99794e723e10a052fd93064391809bfc5a1d3570331a7041afeec64"
    [mycobacterium_tuberculosis__01.seq]="ff54e05bb825b5e8d0410c5c4535cc9a91d7103e1a14962639dfd4531e295e37"
    [streptococcus_pneumoniae__01_1_16.seq]="b7a484cc02ce8cccf33e18b897def7a2cafa59d8967444c43395fe69b7236a2b"
    [streptococcus_pneumoniae__01_1_4.seq]="ec2325ebaef6db52b3614972690edd09f2558bf49ff59ab7d68935415e595129"
    [streptococcus_pneumoniae__01_1_64.seq]="a82ea6a6297cabb030f2b3477eee3f1852fa66a732733575f39e2ea2a8696b03"
    [streptococcus_pneumoniae__01.seq]="656fe5ff3c24cc73c222592f4fd7b1c1ec88ed77ac0078e49711ebdeb2e8f897"
)

# Header only written if the CSV doesn't exist yet, so re-running after
# commenting out finished jobs keeps appending to the same file instead of
# wiping previous results.
if [ ! -f "$out_file" ]; then
    echo "file,compressor,compressed_size,compression_ratio,compression_time,decompression_time,avg_cpu_compression,avg_cpu_decompression,is_correct" \
        > "$out_file"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Compares the decompressed file's sha256 against the hardcoded original
# hash - only ever reads the (small-ish) decompressed output, never the
# original file again.
is_correct() {
    local decompressed_file="$1" expected_hash="$2"
    [ -f "$decompressed_file" ] || { echo 0; return; }
    local actual_hash
    actual_hash="$(sha256sum "$decompressed_file" | awk '{print $1}')"
    [ "$actual_hash" = "$expected_hash" ] && echo 1 || echo 0
}

log_result() {
    # file compressor comp_size ratio comp_time decomp_time cpu_comp cpu_decomp correct
    echo "$1,$2,$3,$4,$5,$6,$7,$8,$9" >> "$out_file"
    echo "[$1] compressor=$2 ratio=$4 correct=$9"
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

sevenzip_compress()   { "${tools[7zip]}" a -mmt=on "-mx=5" "$1" "$seq_file" >> "$log_file" 2>&1; }
sevenzip_decompress() { "${tools[7zip]}" x -y "$1" "-o$2" >> "$log_file" 2>&1; }

zstd_compress()   { "${tools[zstd]}" -T0 -17 -q -f -o "$1" "$seq_file" >> "$log_file" 2>&1; }
zstd_decompress() { "${tools[zstd]}" -T0 -d -q -f -o "$2/$filename" "$1" >> "$log_file" 2>&1; }

bzip3_compress()   { "${tools[bzip3]}" -j "$nproc_count" -b256 -e -c "$seq_file" > "$1" 2>>"$log_file"; }
bzip3_decompress() { "${tools[bzip3]}" -j "$nproc_count" -d -c "$1" > "$2/$filename" 2>>"$log_file"; }

bsc_compress()   { "${tools[bsc]}" e "$seq_file" "$1" -b2047 >> "$log_file" 2>&1; }
bsc_decompress() { "${tools[bsc]}" d "$1" "$2/$filename" >> "$log_file" 2>&1; }

config_info() {
    case "$1" in
        7zip)  printf '%s\t%s\t%s\n' "7zip -mx=5"  sevenzip_compress sevenzip_decompress ;;
        zstd)  printf '%s\t%s\t%s\n' "zstd -17"    zstd_compress      zstd_decompress    ;;
        bzip3) printf '%s\t%s\t%s\n' "bzip3 -b256" bzip3_compress     bzip3_decompress   ;;
        bsc)   printf '%s\t%s\t%s\n' "bsc -b2047"  bsc_compress       bsc_decompress     ;;
        *) echo "Unknown config tag: $1" >&2; return 1 ;;
    esac
}

run_job() {
    local job_filename="$1" tag="$2"
    seq_file="$data_dir/$job_filename"
    filename="$job_filename"

    if [ ! -f "$seq_file" ]; then
        echo "Skipping missing file: $seq_file" >&2
        return
    fi
    original_size="$(stat -c%s "$seq_file")"

    local expected_hash="${file_hashes[$filename]:-}"
    if [ -z "$expected_hash" ] || [ "$expected_hash" = "REPLACE_ME" ]; then
        echo "No hash on file for $filename - run ./generate_hashes.sh and fill in file_hashes. Skipping." >&2
        return
    fi

    local display compress_fn decompress_fn
    IFS=$'\t' read -r display compress_fn decompress_fn < <(config_info "$tag")

    echo "=== $filename [$display] $(date) ===" >> "$log_file"

    local dir archive out
    dir="$(mktmp_dir "$tag")"
    archive="$dir/$filename.$tag"
    out="$dir/$filename"

    local comp_time comp_cpu
    read -r comp_time comp_cpu < <(timed_run "$compress_fn" "$archive")
    local comp_size ratio
    comp_size="$(stat -c%s "$archive" 2>/dev/null || echo 0)"
    ratio="$(awk -v a="$comp_size" -v b="$original_size" 'BEGIN{printf "%.4f", (b>0)?a/b:0}')"

    local decomp_time decomp_cpu
    read -r decomp_time decomp_cpu < <(timed_run "$decompress_fn" "$archive" "$dir")
    local correct
    correct="$(is_correct "$out" "$expected_hash")"

    log_result "$filename" "$display" \
        "$comp_size" "$ratio" "$comp_time" "$decomp_time" "$comp_cpu" "$decomp_cpu" "$correct"
    rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# Job list - one file x one config per line, run strictly in order, one at
# a time. Comment out (#) any line already completed before re-running, so
# a crash/interruption only costs you the remaining lines, not everything.
# ---------------------------------------------------------------------------

jobs=(
    # "achromobacter_xylosoxidans__01.seq:7zip"
    # "achromobacter_xylosoxidans__01.seq:zstd"
    # "achromobacter_xylosoxidans__01.seq:bzip3"
    # "achromobacter_xylosoxidans__01.seq:bsc"
    # "achromobacter_xylosoxidans__01_1_4.seq:7zip"
    # "achromobacter_xylosoxidans__01_1_4.seq:zstd"
    # "achromobacter_xylosoxidans__01_1_4.seq:bzip3"
    # "achromobacter_xylosoxidans__01_1_4.seq:bsc"
    # "achromobacter_xylosoxidans__01_1_16.seq:7zip"
    # "achromobacter_xylosoxidans__01_1_16.seq:zstd"
    # "achromobacter_xylosoxidans__01_1_16.seq:bzip3"
    # "achromobacter_xylosoxidans__01_1_16.seq:bsc"
    # "achromobacter_xylosoxidans__01_1_64.seq:7zip"
    # "achromobacter_xylosoxidans__01_1_64.seq:zstd"
    # "achromobacter_xylosoxidans__01_1_64.seq:bzip3"
    # "achromobacter_xylosoxidans__01_1_64.seq:bsc"

    # "escherichia_coli__01.seq:7zip"
    # "escherichia_coli__01.seq:zstd"
    # "escherichia_coli__01.seq:bzip3"
    # "escherichia_coli__01.seq:bsc"
    # "escherichia_coli__01_1_4.seq:7zip"
    # "escherichia_coli__01_1_4.seq:zstd"
    # "escherichia_coli__01_1_4.seq:bzip3"
    # "escherichia_coli__01_1_4.seq:bsc"
    # "escherichia_coli__01_1_16.seq:7zip"
    # "escherichia_coli__01_1_16.seq:zstd"
    # "escherichia_coli__01_1_16.seq:bzip3"
    # "escherichia_coli__01_1_16.seq:bsc"
    # "escherichia_coli__01_1_64.seq:7zip"
    # "escherichia_coli__01_1_64.seq:zstd"
    # "escherichia_coli__01_1_64.seq:bzip3"
    # "escherichia_coli__01_1_64.seq:bsc"

    # "listeria_monocytogenes__01.seq:7zip"
    # "listeria_monocytogenes__01.seq:zstd"
    # "listeria_monocytogenes__01.seq:bzip3"
    # "listeria_monocytogenes__01.seq:bsc"
    # "listeria_monocytogenes__01_1_4.seq:7zip"
    # "listeria_monocytogenes__01_1_4.seq:zstd"
    # "listeria_monocytogenes__01_1_4.seq:bzip3"
    # "listeria_monocytogenes__01_1_4.seq:bsc"
    # "listeria_monocytogenes__01_1_16.seq:7zip"
    # "listeria_monocytogenes__01_1_16.seq:zstd"
    # "listeria_monocytogenes__01_1_16.seq:bzip3"
    # "listeria_monocytogenes__01_1_16.seq:bsc"
    # "listeria_monocytogenes__01_1_64.seq:7zip"
    # "listeria_monocytogenes__01_1_64.seq:zstd"
    # "listeria_monocytogenes__01_1_64.seq:bzip3"
    # "listeria_monocytogenes__01_1_64.seq:bsc"

    # "mycobacterium_tuberculosis__01.seq:7zip"
    # "mycobacterium_tuberculosis__01.seq:zstd"
    # "mycobacterium_tuberculosis__01.seq:bzip3"
    "mycobacterium_tuberculosis__01.seq:bsc"
    # "mycobacterium_tuberculosis__01_1_4.seq:7zip"
    # "mycobacterium_tuberculosis__01_1_4.seq:zstd"
    # "mycobacterium_tuberculosis__01_1_4.seq:bzip3"
    # "mycobacterium_tuberculosis__01_1_4.seq:bsc"
    # "mycobacterium_tuberculosis__01_1_16.seq:7zip"
    # "mycobacterium_tuberculosis__01_1_16.seq:zstd"
    # "mycobacterium_tuberculosis__01_1_16.seq:bzip3"
    # "mycobacterium_tuberculosis__01_1_16.seq:bsc"
    # "mycobacterium_tuberculosis__01_1_64.seq:7zip"
    # "mycobacterium_tuberculosis__01_1_64.seq:zstd"
    # "mycobacterium_tuberculosis__01_1_64.seq:bzip3"
    # "mycobacterium_tuberculosis__01_1_64.seq:bsc"

    # "streptococcus_pneumoniae__01.seq:7zip"
    # "streptococcus_pneumoniae__01.seq:zstd"
    # "streptococcus_pneumoniae__01.seq:bzip3"
    "streptococcus_pneumoniae__01.seq:bsc"
    # "streptococcus_pneumoniae__01_1_4.seq:7zip"
    # "streptococcus_pneumoniae__01_1_4.seq:zstd"
    # "streptococcus_pneumoniae__01_1_4.seq:bzip3"
    # "streptococcus_pneumoniae__01_1_4.seq:bsc"
    # "streptococcus_pneumoniae__01_1_16.seq:7zip"
    # "streptococcus_pneumoniae__01_1_16.seq:zstd"
    # "streptococcus_pneumoniae__01_1_16.seq:bzip3"
    # "streptococcus_pneumoniae__01_1_16.seq:bsc"
    # "streptococcus_pneumoniae__01_1_64.seq:7zip"
    # "streptococcus_pneumoniae__01_1_64.seq:zstd"
    # "streptococcus_pneumoniae__01_1_64.seq:bzip3"
    # "streptococcus_pneumoniae__01_1_64.seq:bsc"
)

# ---------------------------------------------------------------------------
# Run jobs strictly one at a time, in order.
# ---------------------------------------------------------------------------

for job in "${jobs[@]}"; do
    job_filename="${job%%:*}"
    tag="${job##*:}"
    run_job "$job_filename" "$tag"
done

echo "exp2 complete; results saved to $out_file"