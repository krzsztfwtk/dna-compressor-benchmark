#!/bin/bash

export XZ_OPT="-T0"
BASE_URL="https://ftp.ebi.ac.uk/pub/databases/AllTheBacteria/Releases/0.2/assembly/"

TARGET_ARCHIVES=(
  "achromobacter_xylosoxidans__01.asm.tar.xz"
  "escherichia_coli__01.asm.tar.xz"
  "listeria_monocytogenes__01.asm.tar.xz"
  "mycobacterium_tuberculosis__01.asm.tar.xz"
  "streptococcus_pneumoniae__01.asm.tar.xz"
)

mkdir -p ./data

# Download files
printf "${BASE_URL}%s\n" "${TARGET_ARCHIVES[@]}" | xargs -n 1 -P 0 wget -q -c -P ./data/

# Extract files
for file in ./data/*.tar.xz; do
  tar -xf "$file" -C ./data &
done
wait

# Clear and merge genome files to pure dna .seq file for each species
for dir in ./data/*/; do
  (
    dir_name=$(basename "$dir")
    find "$dir" -maxdepth 1 -name "*.fa" -exec cat {} + 2>/dev/null | awk 'NR % 2 == 0' > "./data/${dir_name}.seq"
    rm -rf "$dir"
  ) &
done
wait

# Generate smaller partial files
for seq_file in ./data/*.seq; do
  if [[ -f "$seq_file" && ! "$seq_file" =~ _1_[0-9]+\.seq$ ]]; then
    (
      file_size=$(wc -c < "$seq_file")
      base_name="${seq_file%.seq}"
      head -c $((file_size / 4)) "$seq_file" > "${base_name}_1_4.seq" &
      head -c $((file_size / 16)) "$seq_file" > "${base_name}_1_16.seq" &
      head -c $((file_size / 64)) "$seq_file" > "${base_name}_1_64.seq" &
      wait
    ) &
  fi
done
wait