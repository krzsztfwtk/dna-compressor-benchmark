#requires -Version 5.1

$root_dir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$data_dir    = Join-Path $root_dir "data"
$bin_dir     = Join-Path $root_dir "bin"
$results_dir = Join-Path $root_dir "results"
$work_dir    = Join-Path $results_dir "tmp"

$seq_file = Join-Path $data_dir "achromobacter_xylosoxidans__01.seq"
$out_file = Join-Path $results_dir "exp1_windows.csv"
$log_file = Join-Path $results_dir "exp1_windows.log"

New-Item -ItemType Directory -Path $results_dir, $work_dir -Force | Out-Null
$env:Path = "$((Resolve-Path $bin_dir).Path);$env:Path"
$env:NUMBER_OF_PROCESSORS = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$env:OMP_NUM_THREADS = $env:NUMBER_OF_PROCESSORS # for bsc compressor

$filename      = Split-Path $seq_file -Leaf
$original_size = (Get-Item $seq_file).Length
$original_hash = (Get-FileHash -Path $seq_file -Algorithm SHA256).Hash

function Get-ToolCommand {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

$candidateNames = @{
    "7z"       = @("7z", "7z.exe")
    "gzip"     = @("gzip", "gzip.exe")
    "zstd"     = @("zstd", "zstd.exe")
    "bzip3"    = @("bzip3", "bzip3.exe")
    "pigz"     = @("pigz", "pigz.exe")
    "bsc"      = @("bsc", "bsc.exe")
    "mcm"      = @("mcm", "mcm.exe")
    "ppmd"     = @("PPMd", "PPMd.exe", "ppmd", "ppmd.exe")
    "ppmonstr" = @("PPMonstr", "PPMonstr.exe", "ppmonstr", "ppmonstr.exe")
    "zcm"      = @("zcm", "zcm.exe", "zcmx64", "zcmx64.exe")
}

$tools   = @{}
$missing = @()
foreach ($key in $candidateNames.Keys) {
    $resolved = Get-ToolCommand -Candidates $candidateNames[$key]
    $tools[$key] = $resolved
    if (-not $resolved) { $missing += $key }
}

if ($missing.Count -gt 0) {
    Write-Host "Missing compressors (not found in bin\ or on PATH): $($missing -join ', ')"
    exit 1
}

"compressor,level,compressed_size,compression_ratio,compression_time,decompression_time,avg_cpu_compression,avg_cpu_decompression,is_correct" |
    Out-File -FilePath $out_file -Encoding utf8

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-Correctness {
    param($Decompressed, $ExpectedHash)

    if (-not (Test-Path $Decompressed)) { return 0 }
    $actualHash = (Get-FileHash -Path $Decompressed -Algorithm SHA256).Hash
    return [int]($actualHash -eq $ExpectedHash)
}

function Add-ResultRow {
    param($Compressor, $Level, $CompSize, $Ratio, $CompTime, $DecompTime, $CpuComp, $CpuDecomp, $IsCorrect)
    "$Compressor,$Level,$CompSize,$Ratio,$CompTime,$DecompTime,$CpuComp,$CpuDecomp,$IsCorrect" |
        Out-File -FilePath $out_file -Append -Encoding utf8
    Write-Host "Processed $filename [Compressor: $Compressor, Level: $Level] Correct: $IsCorrect"
}

function New-ScratchDir {
    param([string]$Tag)
    $dir = Join-Path $work_dir "$Tag`_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Measure-CommandWithCpu {
    param([scriptblock]$Block)
    
    $job = Start-Job -ScriptBlock {
        while ($true) {
            (Get-CimInstance Win32_Processor).LoadPercentage
            Start-Sleep -Milliseconds 200
        }
    }
    
    Start-Sleep -Milliseconds 400

    $seconds = (Measure-Command { & $Block }).TotalSeconds
    
    Stop-Job $job | Out-Null
    $samples = Receive-Job $job
    Remove-Job $job -Force

    $avgCpu = if ($samples) { [math]::Round(($samples | Measure-Object -Average).Average, 2) } else { 0 }
    return @{ Seconds = [math]::Round($seconds, 4); Cpu = $avgCpu }
}

# ---------------------------------------------------------------------------
# Generic runner - compressors that accept arbitrary in/out paths
# (7z, gzip, zstd, bzip3, pigz, bsc). Both blocks decompress into
# "$dir\$filename" so the caller doesn't need a returned path.
# ---------------------------------------------------------------------------

function Invoke-StandardSweep {
    param($Name, $Levels, [scriptblock]$Compress, [scriptblock]$Decompress)
    foreach ($level in $Levels) {
        $dir         = New-ScratchDir $Name
        $archive     = Join-Path $dir "$filename.$Name"
        $decomp_file = Join-Path $dir $filename

        $comp   = Measure-CommandWithCpu { & $Compress $level $archive }
        $comp_size = (Get-Item $archive).Length
        $ratio     = [math]::Round($comp_size / $original_size, 4)

        $decomp = Measure-CommandWithCpu { & $Decompress $archive $dir }
        $iscorrect = Test-Correctness $decomp_file $original_hash

        Add-ResultRow $Name $level $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
        Remove-Item $dir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# In-place runner - mcm / PPMd / PPMonstr can't take a custom decompression
# path and won't reference files outside the working directory, so each
# level runs Push-Location'd into its own scratch dir with the input copied
# in as a bare filename; decompression overwrites that same filename.
# ---------------------------------------------------------------------------

function Invoke-InPlaceSweep {
    param($Name, $Levels, [scriptblock]$Compress, [scriptblock]$Decompress)
    foreach ($level in $Levels) {
        $dir   = New-ScratchDir $Name
        $local = Join-Path $dir $filename
        Copy-Item $seq_file $local

        Push-Location $dir
        $comp = Measure-CommandWithCpu { & $Compress $level }
        $comp_size = (Get-ChildItem $dir -File | Where-Object Name -ne $filename | Select-Object -First 1).Length
        $ratio     = [math]::Round($comp_size / $original_size, 4)

        Remove-Item $local -Force
        $decomp = Measure-CommandWithCpu { & $Decompress }
        Pop-Location

        $iscorrect = Test-Correctness $local $original_hash
        Add-ResultRow $Name $level $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
        Remove-Item $dir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# ZCM runner - decompression into a target dir nests the stored relative
# path, so the output file is located with a recursive search afterwards.
# ---------------------------------------------------------------------------

function Invoke-ZcmSweep {
    param($Levels)
    foreach ($level in $Levels) {
        $dir         = New-ScratchDir "zcm"
        $archive     = Join-Path $dir "$filename.zcm"
        $extract_dir = Join-Path $dir "extract"
        New-Item -ItemType Directory -Path $extract_dir -Force | Out-Null

        $comp = Measure-CommandWithCpu { & $tools["zcm"] a "-m$level" "-t0" $archive $seq_file *>$null }
        $comp_size = (Get-Item $archive).Length
        $ratio     = [math]::Round($comp_size / $original_size, 4)

        $decomp = Measure-CommandWithCpu { & $tools["zcm"] x "-t0" $archive $extract_dir *>$null }
        $decomp_file = Get-ChildItem $extract_dir -Recurse -Filter $filename | Select-Object -First 1 -ExpandProperty FullName

        $iscorrect = Test-Correctness $decomp_file $original_hash
        Add-ResultRow "zcm" $level $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
        Remove-Item $dir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Sweeps
# ---------------------------------------------------------------------------

Invoke-StandardSweep -Name "7zip" -Levels 1, 2, 3, 4, 5, 6, 7, 8, 9 `
    -Compress  { param($level, $archive) & $tools["7z"] a -mmt=on "-mx=$level" $archive $seq_file *>> $log_file } `
    -Decompress { param($archive, $dir) & $tools["7z"] x -y $archive "-o$dir" *>> $log_file }

Invoke-StandardSweep -Name "gzip" -Levels 1, 2, 3, 4, 5, 6, 7, 8, 9 `
    -Compress  { param($level, $archive) cmd /c "`"$($tools['gzip'])`" -$level -c `"$seq_file`" > `"$archive`"" } `
    -Decompress { param($archive, $dir) cmd /c "`"$($tools['gzip'])`" -d -c `"$archive`" > `"$dir\$filename`"" }

Invoke-StandardSweep -Name "zstd" -Levels 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 `
    -Compress  { param($level, $archive) & $tools["zstd"] -T0 "-$level" -q -f -o $archive $seq_file *>> $log_file } `
    -Decompress { param($archive, $dir) & $tools["zstd"] -T0 -d -q -f -o "$dir\$filename" $archive *>> $log_file }

Invoke-StandardSweep -Name "pigz" -Levels 1, 2, 3, 4, 5, 6, 7, 8, 9 `
    -Compress  { param($level, $archive) cmd /c "`"$($tools['pigz'])`" -$level -c -k `"$seq_file`" > `"$archive`"" } `
    -Decompress { param($archive, $dir) cmd /c "`"$($tools['pigz'])`" -d -c `"$archive`" > `"$dir\$filename`"" }

Invoke-StandardSweep -Name "bzip3" -Levels "-b8", "-b16", "-b32", "-b64", "-b128", "-b256" `
    -Compress  { param($level, $archive) cmd /c "`"$($tools['bzip3'])`" -j $env:NUMBER_OF_PROCESSORS $level -e -c `"$seq_file`" > `"$archive`" 2>> $log_file" } `
    -Decompress { param($archive, $dir) cmd /c "`"$($tools['bzip3'])`" -j $env:NUMBER_OF_PROCESSORS -d -c `"$archive`" > `"$dir\$filename`" 2>> $log_file" }

Invoke-StandardSweep -Name "bsc" -Levels "-b10", "-b25", "-b50", "-b100", "-b200", "-b400", "-b800", "-b1600", "-b2047" `
    -Compress  { param($level, $archive) & $tools["bsc"] e $seq_file $archive $level *>> $log_file } `
    -Decompress { param($archive, $dir) & $tools["bsc"] d $archive "$dir\$filename" *>> $log_file }

Invoke-InPlaceSweep -Name "mcm" -Levels "-t", "-f", "-m", "-h", "-x" `
    -Compress  { param($level) & $tools["mcm"] $level $filename "$filename.mcm" *>> $log_file } `
    -Decompress { & $tools["mcm"] d "$filename.mcm" $filename *>> $log_file }

Invoke-InPlaceSweep -Name "PPMd" -Levels "-o2", "-o4", "-o8", "-o12", "-o16" `
    -Compress  { param($level) & $tools["ppmd"] e -m256 $level "-f$filename.pmd" $filename *>> $log_file } `
    -Decompress { & $tools["ppmd"] d "$filename.pmd" *>> $log_file }

Invoke-InPlaceSweep -Name "PPMonstr" -Levels "-o4", "-o8", "-o16", "-o32" `
    -Compress  { param($level) & $tools["ppmonstr"] e -m1536 $level "-f$filename.ppmonstr" $filename *>> $log_file } `
    -Decompress { & $tools["ppmonstr"] d "$filename.ppmonstr" *>> $log_file }

Invoke-ZcmSweep -Levels 1, 2, 3, 4, 5, 6, 7, 8

Remove-Item $work_dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "exp1 complete; results saved to $out_file"