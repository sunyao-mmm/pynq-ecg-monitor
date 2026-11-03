param(
    [string]$ModelSimBin = 'D:\modeltech64_10.4\win64'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sourceRepo = $repo
$stageRoot = $null

# ModelSim 10.4 cannot reliably create its SQLite library under a non-ASCII
# path.  Stage only the simulation inputs when the repository path contains
# CJK characters, while writing final logs back to the submission directory.
if ($repo -match '[^\x00-\x7F]') {
    $stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('ecg_pynq_modelsim_' + [guid]::NewGuid().ToString('N'))
    $stageRtl = Join-Path $stageRoot 'src\rtl'
    $stageTb = Join-Path $stageRoot 'sim\testbench'
    $stageRom = Join-Path $stageRoot 'data\rom'
    New-Item -ItemType Directory -Path $stageRtl, $stageTb, $stageRom -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceRepo 'src\rtl\*.v') -Destination $stageRtl
    Copy-Item -Path (Join-Path $sourceRepo 'sim\testbench\*.v') -Destination $stageTb
    Copy-Item -LiteralPath (Join-Path $sourceRepo 'data\rom\ecg_rom_208.hex') -Destination $stageRom
    $repo = $stageRoot
}

$rtl = Join-Path $repo 'src\rtl'
$tb = Join-Path $repo 'sim\testbench'
$logs = Join-Path $sourceRepo 'sim\logs'
$workRoot = Join-Path $repo 'sim\work'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'

foreach ($tool in @($vlib, $vlog, $vsim)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "ModelSim executable not found: $tool"
    }
}

New-Item -ItemType Directory -Path $logs -Force | Out-Null
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

$tests = @(
    @{ Name = 'tb_notch_50hz'; Rtl = @('notch_50hz.v') },
    @{ Name = 'tb_heart_rate'; Rtl = @('heart_rate.v') },
    @{ Name = 'tb_ecg_detect'; Rtl = @('notch_50hz.v', 'fir_bandpass.v', 'clt_qrs.v', 'heart_rate.v', 'ecg_detect_top.v') },
    @{ Name = 'tb_ecg_core'; Rtl = @('notch_50hz.v', 'fir_bandpass.v', 'clt_qrs.v', 'heart_rate.v', 'ecg_detect_top.v', 'ecg_core.v') },
    @{ Name = 'tb_ecg_continuous'; Rtl = @('notch_50hz.v', 'fir_bandpass.v', 'clt_qrs.v', 'heart_rate.v', 'ecg_detect_top.v', 'ecg_core.v') },
    @{ Name = 'tb_ring_memory'; Rtl = @('notch_50hz.v', 'fir_bandpass.v', 'clt_qrs.v', 'heart_rate.v', 'ecg_detect_top.v', 'ecg_core.v') },
    @{ Name = 'tb_rom_long'; Rtl = @('notch_50hz.v', 'fir_bandpass.v', 'clt_qrs.v', 'heart_rate.v', 'ecg_detect_top.v', 'ecg_core.v'); Plusargs = @('-gRUNSAMP=75000', ('+HEXFILE=' + ((Join-Path $repo 'data\rom\ecg_rom_208.hex') -replace '\\', '/'))) },
    @{ Name = 'tb_ads1292_spi'; Rtl = @('ads1292_spi.v') },
    @{ Name = 'tb_ecg_axil'; Rtl = @('ecg_axil.v') }
)

$results = foreach ($test in $tests) {
    $work = Join-Path $workRoot $test.Name
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Push-Location $work
    try {
        & $vlib work | Out-Null
        $sources = @()
        $sources += $test.Rtl | ForEach-Object { Join-Path $rtl $_ }
        $sources += Join-Path $tb ($test.Name + '.v')
        $output = @()
        $output += & $vlog @sources 2>&1
        $compileExit = $LASTEXITCODE
        $simArgs = @('-c', $test.Name)
        if ($test.ContainsKey('Plusargs')) {
            $simArgs += $test.Plusargs
        }
        $output += & $vsim @simArgs -do 'run -all; quit -f' 2>&1
        $simExit = $LASTEXITCODE
        $output | Set-Content -LiteralPath (Join-Path $logs ($test.Name + '.log')) -Encoding utf8
        $text = $output -join "`n"
        [pscustomobject]@{
            Testbench = $test.Name
            Compile = ($compileExit -eq 0)
            Simulation = ($simExit -eq 0)
            ResultPass = (
                $text -match 'RESULT:\s*PASS' -or
                $text -match 'TP = 4\s+FP = 0\s+FN = 0' -or
                $text -match '(?m)^#?\s*PASS\b'
            )
        }
    } finally {
        Pop-Location
    }
}

$results | Format-Table -AutoSize
if ($stageRoot) {
    Write-Host "ModelSim staging directory: $stageRoot"
}
if ($results.Where({ -not $_.Compile -or -not $_.Simulation -or -not $_.ResultPass }).Count -gt 0) {
    exit 1
}
