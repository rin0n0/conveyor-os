# Adds a named "Conveyor OS" entry to this PC's UEFI boot list and restarts into it once.
# The entry then also appears in Windows Recovery under "Use a device".
# Run with -Remove to delete the entry from this PC.
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$EntryName = 'Conveyor OS'
$EspPartitionType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$LoaderPath = '\EFI\BOOT\BOOTX64.EFI'
$GuidPattern = '\{[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}'

function Invoke-Bcd {
    $output = & bcdedit.exe @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($args -join ' '): $output"
    }
    return $output
}

function Get-ConveyorEntryIds {
    $listing = Invoke-Bcd /enum firmware /v
    foreach ($block in ($listing -split '(\r?\n){2,}')) {
        if ($block -match [regex]::Escape($EntryName) -and $block -match $GuidPattern) {
            $Matches[0]
        }
    }
}

function Get-FreeDriveLetter {
    $used = (Get-Volume | Where-Object DriveLetter).DriveLetter
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        if ($used -notcontains $letter -and -not (Test-Path "${letter}:\")) {
            return $letter
        }
    }
    throw 'Нет свободной буквы диска.'
}

try {
    foreach ($id in @(Get-ConveyorEntryIds)) {
        Invoke-Bcd /delete $id | Out-Null
    }

    if ($Remove) {
        Write-Host 'Запись Conveyor OS удалена с этого компьютера.'
        return
    }

    $shareLetter = (Split-Path -Qualifier $PSScriptRoot).TrimEnd(':')
    $diskNumber = (Get-Partition -DriveLetter $shareLetter).DiskNumber
    $esp = Get-Partition -DiskNumber $diskNumber |
        Where-Object { $_.GptType -eq $EspPartitionType } |
        Select-Object -First 1
    if (-not $esp) {
        throw 'На этом диске не найден раздел EFI.'
    }

    $volumePath = $esp.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
    $letter = Get-FreeDriveLetter
    & mountvol.exe "${letter}:" $volumePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Не удалось подключить раздел EFI.'
    }

    try {
        if (-not (Test-Path "${letter}:$LoaderPath")) {
            throw "На диске нет загрузчика $LoaderPath."
        }
        $created = Invoke-Bcd /copy '{bootmgr}' /d $EntryName
        if ($created -notmatch $GuidPattern) {
            throw "Не удалось создать запись: $created"
        }
        $entryId = $Matches[0]
        Invoke-Bcd /set $entryId device "partition=${letter}:" | Out-Null
        Invoke-Bcd /set $entryId path $LoaderPath | Out-Null
        Invoke-Bcd /set '{fwbootmgr}' displayorder $entryId /addlast | Out-Null
    }
    finally {
        & mountvol.exe "${letter}:" /D
    }

    Write-Host 'Готово: Conveyor OS добавлена в список загрузки этого компьютера.'
    Write-Host 'Windows останется загрузкой по умолчанию.'

    $bitLocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($bitLocker -and $bitLocker.ProtectionStatus -eq 'On') {
        Write-Warning 'Диск Windows защищён BitLocker. Убедитесь, что у вас есть ключ восстановления.'
    }

    $answer = Read-Host 'Перезагрузиться в Conveyor OS сейчас? (y/n)'
    if ($answer -match '^(y|д)') {
        Invoke-Bcd /set '{fwbootmgr}' bootsequence $entryId | Out-Null
        & shutdown.exe /r /t 0
    }
}
catch {
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Нажмите Enter для выхода' | Out-Null
    exit 1
}
