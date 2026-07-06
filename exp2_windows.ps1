#requires -Version 5.1

$root_dir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$data_dir    = Join-Path $root_dir "data"
$bin_dir     = Join-Path $root_dir "bin"
$results_dir = Join-Path $root_dir "results"
$work_dir    = Join-Path $results_dir "tmp"

$out_file = Join-Path $results_dir "exp2_windows.csv"
$log_file = Join-Path $results_dir "exp2_windows.log"

New-Item -ItemType Directory -Path $results_dir, $work_dir -Force | Out-Null
$env:Path = "$((Resolve-Path $bin_dir).Path);$env:Path"
$env:NUMBER_OF_PROCESSORS = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$env:OMP_NUM_THREADS = $env:NUMBER_OF_PROCESSORS # for bsc compressor

function Get-ToolCommand {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Only the tools needed for the exp1 winners
$candidateNames = @{
    "7z"    = @("7z", "7z.exe")
    "zstd"  = @("zstd", "zstd.exe")
    "bzip3" = @("bzip3", "bzip3.exe")
    "bsc"   = @("bsc", "bsc.exe")
    "zcm"   = @("zcm", "zcm.exe", "zcmx64", "zcmx64.exe")
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

# ---------------------------------------------------------------------------
# Hardcoded sha256 of every original .seq file.
# Avoids re-reading the
# original file on every correctness check: we only ever hash
# the decompressed output and compare against these.
# ---------------------------------------------------------------------------

$file_hashes = @{
    "achromobacter_xylosoxidans__01.seq" = "f65d1b661c0cb437de690f0fdb89d03f882ce7e829c68a29e69a908c84513f38"
    "achromobacter_xylosoxidans__01_1_16.seq" = "293a5423d5280b191d1ee6928e8893f7bacaaad782f5f83c27061e594bdc5d82"
    "achromobacter_xylosoxidans__01_1_4.seq" = "32c0fd59566c989bcd2f820b94df68bab3ba749f62dafa26fd585b1e9425c8d3"
    "achromobacter_xylosoxidans__01_1_64.seq" = "4b28dad96791dfa7655b1af06c4bceff703dcc33fecf729198d5e779fab3cdcb"
    "escherichia_coli__01.seq" = "7435e521b5042fd6844ddc790bbbd616e270c046155ca3208d2edfdfdb07d5ed"
    "escherichia_coli__01_1_16.seq" = "199ef9eb0f64dbd1c93abab37dadb6d0aff9e88d39d473ac6bf02b874fc90737"
    "escherichia_coli__01_1_4.seq" = "6d2bca82447989b99a29bcb610b8f8ed596bfde199c2db34fb95715134d0da7e"
    "escherichia_coli__01_1_64.seq" = "80e80a0ad4237e19aa551c085cc7bb3fde3ee0645588e22dc6a8d10eae31c4c3"
    "listeria_monocytogenes__01.seq" = "c4e569403b4f7fd540dbaee2ccd318965e4a96b9475fd1fccdd4713d18ff7ca2"
    "listeria_monocytogenes__01_1_16.seq" = "bf7782415bdd11cbf84ef9aa845f03b9bed471dbffe3a67a11ec39b9834707b8"
    "listeria_monocytogenes__01_1_4.seq" = "c50bd24d356f0064b511c0d566fae303ef0129419da1996a42b1f057c50a125d"
    "listeria_monocytogenes__01_1_64.seq" = "4ca84b4e518124f0bfdd4bc684d97e09a82f17d8e4027b14b93a7ace53550ef7"
    "mycobacterium_tuberculosis__01.seq" = "ff54e05bb825b5e8d0410c5c4535cc9a91d7103e1a14962639dfd4531e295e37"
    "mycobacterium_tuberculosis__01_1_16.seq" = "8293d20bfb16dedce7f73aa75514451f16acaa2f138800507822e66cfa698847"
    "mycobacterium_tuberculosis__01_1_4.seq" = "aa966350dd3ef8334231ec645ec905e01ebeb122ac02359d790b06d761f45785"
    "mycobacterium_tuberculosis__01_1_64.seq" = "79c5f217b99794e723e10a052fd93064391809bfc5a1d3570331a7041afeec64"
    "streptococcus_pneumoniae__01.seq" = "656fe5ff3c24cc73c222592f4fd7b1c1ec88ed77ac0078e49711ebdeb2e8f897"
    "streptococcus_pneumoniae__01_1_16.seq" = "b7a484cc02ce8cccf33e18b897def7a2cafa59d8967444c43395fe69b7236a2b"
    "streptococcus_pneumoniae__01_1_4.seq" = "ec2325ebaef6db52b3614972690edd09f2558bf49ff59ab7d68935415e595129"
    "streptococcus_pneumoniae__01_1_64.seq" = "a82ea6a6297cabb030f2b3477eee3f1852fa66a732733575f39e2ea2a8696b03"
}

# Header only written if the CSV doesn't exist yet, so re-running after
# commenting out finished jobs keeps appending instead of wiping results.
if (-not (Test-Path $out_file)) {
    "file,compressor,compressed_size,compression_ratio,compression_time,decompression_time,avg_cpu_compression,avg_cpu_decompression,is_correct" |
        Out-File -FilePath $out_file -Encoding utf8
}

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
    param($File, $Compressor, $CompSize, $Ratio, $CompTime, $DecompTime, $CpuComp, $CpuDecomp, $IsCorrect)
    "$File,$Compressor,$CompSize,$Ratio,$CompTime,$DecompTime,$CpuComp,$CpuDecomp,$IsCorrect" |
        Out-File -FilePath $out_file -Append -Encoding utf8
    Write-Host "[$File] Compressor: $Compressor, Correct: $IsCorrect"
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

function Invoke-SevenZip {
    param($SeqFile, $Filename, $OriginalSize, $ExpectedHash)
    $dir     = New-ScratchDir "7zip"
    $archive = Join-Path $dir "$Filename.7zip"
    $comp    = Measure-CommandWithCpu { & $tools["7z"] a -mmt=on "-mx=5" $archive $SeqFile *>> $log_file }
    $comp_size = (Get-Item $archive).Length
    $ratio     = [math]::Round($comp_size / $OriginalSize, 4)
    $decomp    = Measure-CommandWithCpu { & $tools["7z"] x -y $archive "-o$dir" *>> $log_file }
    $decomp_file = Join-Path $dir $Filename
    $iscorrect = Test-Correctness $decomp_file $ExpectedHash
    Add-ResultRow $Filename "7zip -mx=5" $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
    Remove-Item $dir -Recurse -Force
}

function Invoke-Zstd {
    param($SeqFile, $Filename, $OriginalSize, $ExpectedHash)
    $dir     = New-ScratchDir "zstd"
    $archive = Join-Path $dir "$Filename.zstd"
    $comp    = Measure-CommandWithCpu { & $tools["zstd"] -T0 -17 -q -f -o $archive $SeqFile *>> $log_file }
    $comp_size = (Get-Item $archive).Length
    $ratio     = [math]::Round($comp_size / $OriginalSize, 4)
    $decomp_file = Join-Path $dir $Filename
    $decomp    = Measure-CommandWithCpu { & $tools["zstd"] -T0 -d -q -f -o $decomp_file $archive *>> $log_file }
    $iscorrect = Test-Correctness $decomp_file $ExpectedHash
    Add-ResultRow $Filename "zstd -17" $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
    Remove-Item $dir -Recurse -Force
}

function Invoke-Bzip3 {
    param($SeqFile, $Filename, $OriginalSize, $ExpectedHash)
    $dir     = New-ScratchDir "bzip3"
    $archive = Join-Path $dir "$Filename.bzip3"
    $decomp_file = Join-Path $dir $Filename
    $comp    = Measure-CommandWithCpu { cmd /c "`"$($tools['bzip3'])`" -j $env:NUMBER_OF_PROCESSORS -b256 -e -c `"$SeqFile`" > `"$archive`" 2>> $log_file" }
    $comp_size = (Get-Item $archive).Length
    $ratio     = [math]::Round($comp_size / $OriginalSize, 4)
    $decomp    = Measure-CommandWithCpu { cmd /c "`"$($tools['bzip3'])`" -j $env:NUMBER_OF_PROCESSORS -d -c `"$archive`" > `"$decomp_file`" 2>> $log_file" }
    $iscorrect = Test-Correctness $decomp_file $ExpectedHash
    Add-ResultRow $Filename "bzip3 -b256" $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
    Remove-Item $dir -Recurse -Force
}

function Invoke-Bsc {
    param($SeqFile, $Filename, $OriginalSize, $ExpectedHash)
    $dir     = New-ScratchDir "bsc"
    $archive = Join-Path $dir "$Filename.bsc"
    $decomp_file = Join-Path $dir $Filename
    $comp    = Measure-CommandWithCpu { & $tools["bsc"] e $SeqFile $archive -b2047 *>> $log_file }
    $comp_size = (Get-Item $archive).Length
    $ratio     = [math]::Round($comp_size / $OriginalSize, 4)
    $decomp    = Measure-CommandWithCpu { & $tools["bsc"] d $archive $decomp_file *>> $log_file }
    $iscorrect = Test-Correctness $decomp_file $ExpectedHash
    Add-ResultRow $Filename "bsc -b2047" $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
    Remove-Item $dir -Recurse -Force
}

function Invoke-Zcm {
    param($SeqFile, $Filename, $OriginalSize, $ExpectedHash)
    # zcm stores whatever path you hand it and recreates that same relative
    # path on extraction (no -o/target-dir option), so instead of guessing
    # where it landed: compress using a path relative to $root_dir, move the
    # original aside, extract (it reappears at $SeqFile on its own), compare,
    # then always restore the original in `finally` - even on failure - so
    # ./data is never left missing a file.
    $relSeqFile = Join-Path "data" $Filename
    $backupFile = "$SeqFile.orig_backup"
    $archive    = Join-Path $work_dir "$Filename.zcm"
    $comp_size = 0
    $ratio = 0
    $iscorrect = 0
    $comp = @{ Seconds = 0; Cpu = 0 }
    $decomp = @{ Seconds = 0; Cpu = 0 }

    Push-Location $root_dir
    try {
        $comp = Measure-CommandWithCpu { & $tools["zcm"] a "-m7" "-t0" $archive $relSeqFile *>> $log_file }
        if (Test-Path $archive) {
            $comp_size = (Get-Item $archive).Length
            $ratio     = [math]::Round($comp_size / $OriginalSize, 4)
        }

        Move-Item -Path $SeqFile -Destination $backupFile -Force

        $decomp = Measure-CommandWithCpu { & $tools["zcm"] x "-t0" $archive *>> $log_file }

        $iscorrect = Test-Correctness $SeqFile $ExpectedHash
    }
    finally {
        if (Test-Path $SeqFile) { Remove-Item $SeqFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $backupFile) { Move-Item -Path $backupFile -Destination $SeqFile -Force }
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
        Pop-Location
    }

    Add-ResultRow $Filename "zcm -m7" $comp_size $ratio $comp.Seconds $decomp.Seconds $comp.Cpu $decomp.Cpu $iscorrect
}

$configDispatch = @{
    "7zip"  = { param($s,$f,$o,$h) Invoke-SevenZip $s $f $o $h }
    "zstd"  = { param($s,$f,$o,$h) Invoke-Zstd     $s $f $o $h }
    "bzip3" = { param($s,$f,$o,$h) Invoke-Bzip3    $s $f $o $h }
    "bsc"   = { param($s,$f,$o,$h) Invoke-Bsc      $s $f $o $h }
    "zcm"   = { param($s,$f,$o,$h) Invoke-Zcm      $s $f $o $h }
}

function Invoke-Job {
    param($Filename, $Tag)

    $seqFile = Join-Path $data_dir $Filename
    if (-not (Test-Path $seqFile)) {
        Write-Host "Skipping missing file: $seqFile"
        return
    }
    $originalSize = (Get-Item $seqFile).Length

    $expectedHash = $file_hashes[$Filename]
    if (-not $expectedHash -or $expectedHash -eq "REPLACE_ME") {
        Write-Host "No hash on file for $Filename - run .\generate_hashes.ps1 and fill in `$file_hashes. Skipping."
        return
    }

    "=== $Filename [$Tag] $(Get-Date) ===" | Out-File -FilePath $log_file -Append -Encoding utf8

    & $configDispatch[$Tag] $seqFile $Filename $originalSize $expectedHash
}

# ---------------------------------------------------------------------------
# Job list - one file x one config per line, run strictly in order, one at
# a time. Comment out (#) any line already completed before re-running, so
# a crash/interruption only costs you the remaining lines, not everything.
# ---------------------------------------------------------------------------

$jobs = @(
    # @{ File = "achromobacter_xylosoxidans__01.seq";       Tag = "7zip"  }
    # @{ File = "achromobacter_xylosoxidans__01.seq";       Tag = "zstd"  }
    # @{ File = "achromobacter_xylosoxidans__01.seq";       Tag = "bzip3" }
    # @{ File = "achromobacter_xylosoxidans__01.seq";       Tag = "bsc"   }
    # @{ File = "achromobacter_xylosoxidans__01.seq";       Tag = "zcm"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_4.seq";   Tag = "7zip"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_4.seq";   Tag = "zstd"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_4.seq";   Tag = "bzip3" }
    # @{ File = "achromobacter_xylosoxidans__01_1_4.seq";   Tag = "bsc"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_4.seq";   Tag = "zcm"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_16.seq";  Tag = "7zip"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_16.seq";  Tag = "zstd"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_16.seq";  Tag = "bzip3" }
    # @{ File = "achromobacter_xylosoxidans__01_1_16.seq";  Tag = "bsc"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_16.seq";  Tag = "zcm"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_64.seq";  Tag = "7zip"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_64.seq";  Tag = "zstd"  }
    # @{ File = "achromobacter_xylosoxidans__01_1_64.seq";  Tag = "bzip3" }
    # @{ File = "achromobacter_xylosoxidans__01_1_64.seq";  Tag = "bsc"   }
    # @{ File = "achromobacter_xylosoxidans__01_1_64.seq";  Tag = "zcm"   }

    # @{ File = "escherichia_coli__01.seq";                 Tag = "7zip"  }
    # @{ File = "escherichia_coli__01.seq";                 Tag = "zstd"  }
    # @{ File = "escherichia_coli__01.seq";                 Tag = "bzip3" }
    # @{ File = "escherichia_coli__01.seq";                 Tag = "bsc"   }
    # @{ File = "escherichia_coli__01.seq";                 Tag = "zcm"   }
    # @{ File = "escherichia_coli__01_1_4.seq";             Tag = "7zip"  }
    # @{ File = "escherichia_coli__01_1_4.seq";             Tag = "zstd"  }
    # @{ File = "escherichia_coli__01_1_4.seq";             Tag = "bzip3" }
    # @{ File = "escherichia_coli__01_1_4.seq";             Tag = "bsc"   }
    # @{ File = "escherichia_coli__01_1_4.seq";             Tag = "zcm"   }
    # @{ File = "escherichia_coli__01_1_16.seq";            Tag = "7zip"  }
    # @{ File = "escherichia_coli__01_1_16.seq";            Tag = "zstd"  }
    # @{ File = "escherichia_coli__01_1_16.seq";            Tag = "bzip3" }
    # @{ File = "escherichia_coli__01_1_16.seq";            Tag = "bsc"   }
    # @{ File = "escherichia_coli__01_1_16.seq";            Tag = "zcm"   }
    # @{ File = "escherichia_coli__01_1_64.seq";            Tag = "7zip"  }
    # @{ File = "escherichia_coli__01_1_64.seq";            Tag = "zstd"  }
    # @{ File = "escherichia_coli__01_1_64.seq";            Tag = "bzip3" }
    # @{ File = "escherichia_coli__01_1_64.seq";            Tag = "bsc"   }
    # @{ File = "escherichia_coli__01_1_64.seq";            Tag = "zcm"   }

    # @{ File = "listeria_monocytogenes__01.seq";           Tag = "7zip"  }
    # @{ File = "listeria_monocytogenes__01.seq";           Tag = "zstd"  }
    # @{ File = "listeria_monocytogenes__01.seq";           Tag = "bzip3" }
    # @{ File = "listeria_monocytogenes__01.seq";           Tag = "bsc"   }
    # @{ File = "listeria_monocytogenes__01.seq";           Tag = "zcm"   }
    # @{ File = "listeria_monocytogenes__01_1_4.seq";       Tag = "7zip"  }
    # @{ File = "listeria_monocytogenes__01_1_4.seq";       Tag = "zstd"  }
    # @{ File = "listeria_monocytogenes__01_1_4.seq";       Tag = "bzip3" }
    # @{ File = "listeria_monocytogenes__01_1_4.seq";       Tag = "bsc"   }
    # @{ File = "listeria_monocytogenes__01_1_4.seq";       Tag = "zcm"   }
    # @{ File = "listeria_monocytogenes__01_1_16.seq";      Tag = "7zip"  }
    # @{ File = "listeria_monocytogenes__01_1_16.seq";      Tag = "zstd"  }
    # @{ File = "listeria_monocytogenes__01_1_16.seq";      Tag = "bzip3" }
    # @{ File = "listeria_monocytogenes__01_1_16.seq";      Tag = "bsc"   }
    # @{ File = "listeria_monocytogenes__01_1_16.seq";      Tag = "zcm"   }
    # @{ File = "listeria_monocytogenes__01_1_64.seq";      Tag = "7zip"  }
    # @{ File = "listeria_monocytogenes__01_1_64.seq";      Tag = "zstd"  }
    # @{ File = "listeria_monocytogenes__01_1_64.seq";      Tag = "bzip3" }
    # @{ File = "listeria_monocytogenes__01_1_64.seq";      Tag = "bsc"   }
    # @{ File = "listeria_monocytogenes__01_1_64.seq";      Tag = "zcm"   }

    # @{ File = "mycobacterium_tuberculosis__01.seq";       Tag = "7zip"  }
    # @{ File = "mycobacterium_tuberculosis__01.seq";       Tag = "zstd"  }
    # @{ File = "mycobacterium_tuberculosis__01.seq";       Tag = "bzip3" }
    # @{ File = "mycobacterium_tuberculosis__01.seq";       Tag = "bsc"   }
    # @{ File = "mycobacterium_tuberculosis__01.seq";       Tag = "zcm"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_4.seq";   Tag = "7zip"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_4.seq";   Tag = "zstd"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_4.seq";   Tag = "bzip3" }
    # @{ File = "mycobacterium_tuberculosis__01_1_4.seq";   Tag = "bsc"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_4.seq";   Tag = "zcm"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_16.seq";  Tag = "7zip"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_16.seq";  Tag = "zstd"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_16.seq";  Tag = "bzip3" }
    # @{ File = "mycobacterium_tuberculosis__01_1_16.seq";  Tag = "bsc"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_16.seq";  Tag = "zcm"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_64.seq";  Tag = "7zip"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_64.seq";  Tag = "zstd"  }
    # @{ File = "mycobacterium_tuberculosis__01_1_64.seq";  Tag = "bzip3" }
    # @{ File = "mycobacterium_tuberculosis__01_1_64.seq";  Tag = "bsc"   }
    # @{ File = "mycobacterium_tuberculosis__01_1_64.seq";  Tag = "zcm"   }

    # @{ File = "streptococcus_pneumoniae__01.seq";         Tag = "7zip"  }
    # @{ File = "streptococcus_pneumoniae__01.seq";         Tag = "zstd"  }
    # @{ File = "streptococcus_pneumoniae__01.seq";         Tag = "bzip3" }
    # @{ File = "streptococcus_pneumoniae__01.seq";         Tag = "bsc"   }
    # @{ File = "streptococcus_pneumoniae__01.seq";         Tag = "zcm"   }
    # @{ File = "streptococcus_pneumoniae__01_1_4.seq";     Tag = "7zip"  }
    # @{ File = "streptococcus_pneumoniae__01_1_4.seq";     Tag = "zstd"  }
    # @{ File = "streptococcus_pneumoniae__01_1_4.seq";     Tag = "bzip3" }
    # @{ File = "streptococcus_pneumoniae__01_1_4.seq";     Tag = "bsc"   }
    # @{ File = "streptococcus_pneumoniae__01_1_4.seq";     Tag = "zcm"   }
    # @{ File = "streptococcus_pneumoniae__01_1_16.seq";    Tag = "7zip"  }
    # @{ File = "streptococcus_pneumoniae__01_1_16.seq";    Tag = "zstd"  }
    # @{ File = "streptococcus_pneumoniae__01_1_16.seq";    Tag = "bzip3" }
    # @{ File = "streptococcus_pneumoniae__01_1_16.seq";    Tag = "bsc"   }
    # @{ File = "streptococcus_pneumoniae__01_1_16.seq";    Tag = "zcm"   }
    # @{ File = "streptococcus_pneumoniae__01_1_64.seq";    Tag = "7zip"  }
    # @{ File = "streptococcus_pneumoniae__01_1_64.seq";    Tag = "zstd"  }
    # @{ File = "streptococcus_pneumoniae__01_1_64.seq";    Tag = "bzip3" }
    # @{ File = "streptococcus_pneumoniae__01_1_64.seq";    Tag = "bsc"   }
    # @{ File = "streptococcus_pneumoniae__01_1_64.seq";    Tag = "zcm"   }


    @{ File = "escherichia_coli__01.seq";                 Tag = "bzip3" }
    # @{ File = "escherichia_coli__01.seq";                 Tag = "7zip"  }
)

# Run jobs strictly one at a time, in order.
foreach ($j in $jobs) {
    Invoke-Job -Filename $j.File -Tag $j.Tag
}

Remove-Item $work_dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "exp2 complete; results saved to $out_file"