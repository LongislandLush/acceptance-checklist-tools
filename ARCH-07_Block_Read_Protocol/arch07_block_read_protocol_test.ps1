param(
    [string]$Port = "COM18",
    [int]$BaudRate = 19200,
    [ValidateSet("None", "Odd", "Even", "Mark", "Space")]
    [string]$Parity = "Even",
    [int]$SlaveId = 1,
    [int]$StartRegister = 100,
    [int]$Count = 10,
    [int]$ReadTimeoutMs = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ModbusCrc {
    param([byte[]]$Data)

    [int]$crc = 0xFFFF
    foreach ($b in $Data) {
        $crc = $crc -bxor $b
        for ($i = 0; $i -lt 8; $i++) {
            if (($crc -band 0x0001) -ne 0) {
                $crc = ($crc -shr 1) -bxor 0xA001
            } else {
                $crc = $crc -shr 1
            }
        }
    }

    return ,([byte[]]@(
        [byte]($crc -band 0xFF),
        [byte](($crc -shr 8) -band 0xFF)
    ))
}

function New-ReadHoldingRequest {
    param(
        [int]$Slave,
        [int]$StartRegister,
        [int]$RegisterCount
    )

    [byte[]]$pdu = @(
        [byte]$Slave,
        0x03,
        [byte](($StartRegister -shr 8) -band 0xFF),
        [byte]($StartRegister -band 0xFF),
        [byte](($RegisterCount -shr 8) -band 0xFF),
        [byte]($RegisterCount -band 0xFF)
    )
    [byte[]]$crc = Get-ModbusCrc $pdu
    return ,([byte[]]($pdu + $crc))
}

function Format-ByteHex {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Count -eq 0) {
        return "<no bytes>"
    }
    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join " ")
}

function Read-AvailableBytes {
    param([System.IO.Ports.SerialPort]$Serial)

    Start-Sleep -Milliseconds 80
    $buffer = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::UtcNow.AddMilliseconds($ReadTimeoutMs)

    while ([DateTime]::UtcNow -lt $deadline) {
        while ($Serial.BytesToRead -gt 0) {
            $buffer.Add([byte]$Serial.ReadByte())
            Start-Sleep -Milliseconds 5
        }
        Start-Sleep -Milliseconds 10
    }

    return ,([byte[]]$buffer.ToArray())
}

function Get-ValidReadResponse {
    param(
        [byte[]]$Response,
        [int]$ExpectedSlave,
        [int]$ExpectedCount,
        [string]$Label
    )

    $expectedLength = 5 + (2 * $ExpectedCount)

    for ($start = 0; $start -le ($Response.Count - $expectedLength); $start++) {
        if ($Response[$start] -ne [byte]$ExpectedSlave -or $Response[$start + 1] -ne 0x03) {
            continue
        }
        if ($Response[$start + 2] -ne [byte](2 * $ExpectedCount)) {
            continue
        }

        [byte[]]$candidate = $Response[$start..($start + $expectedLength - 1)]
        [byte[]]$body = $candidate[0..($candidate.Count - 3)]
        [byte[]]$expectedCrc = Get-ModbusCrc $body
        if ($candidate[$candidate.Count - 2] -eq $expectedCrc[0] -and $candidate[$candidate.Count - 1] -eq $expectedCrc[1]) {
            if ($Response.Count -ne $expectedLength) {
                Write-Host "      WARN: valid response found with extra byte(s). Raw RX=$(Format-ByteHex $Response)"
            }
            return ,$candidate
        }
    }

    throw "$Label FAIL: no valid Function 03 response found. RX=$(Format-ByteHex $Response)"
}

function Convert-ResponseToRegisters {
    param(
        [byte[]]$Frame,
        [int]$RegisterCount
    )

    $registers = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $RegisterCount; $i++) {
        $hi = $Frame[3 + ($i * 2)]
        $lo = $Frame[4 + ($i * 2)]
        $registers.Add((([int]$hi -shl 8) -bor [int]$lo))
    }
    return $registers.ToArray()
}

if ($Count -lt 2) {
    throw "Count must be 2 or greater for ARCH-07 block read testing."
}
if ($Count -gt 125) {
    throw "Function 03 can read at most 125 holding registers per Modbus request."
}

$baselineRequest = [byte[]](New-ReadHoldingRequest -Slave $SlaveId -StartRegister $StartRegister -RegisterCount 1)
$blockRequest = [byte[]](New-ReadHoldingRequest -Slave $SlaveId -StartRegister $StartRegister -RegisterCount $Count)

Write-Host "ARCH-07 Block Read Protocol Test"
Write-Host "Port=$Port Baud=$BaudRate Parity=$Parity Slave=$SlaveId Function=03 StartRegister=$StartRegister Count=$Count"
Write-Host "Baseline request: $(Format-ByteHex $baselineRequest)"
Write-Host "Block request:    $(Format-ByteHex $blockRequest)"
Write-Host ""

$serial = [System.IO.Ports.SerialPort]::new(
    $Port,
    $BaudRate,
    [System.IO.Ports.Parity]::$Parity,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.ReadTimeout = $ReadTimeoutMs
$serial.WriteTimeout = $ReadTimeoutMs

try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    Write-Host "[1/2] Baseline: read one holding register"
    $serial.Write($baselineRequest, 0, $baselineRequest.Count)
    $baselineRaw = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX: $(Format-ByteHex $baselineRaw)"
    $baselineFrame = [byte[]](Get-ValidReadResponse -Response $baselineRaw -ExpectedSlave $SlaveId -ExpectedCount 1 -Label "Baseline")
    $baselineRegisters = Convert-ResponseToRegisters -Frame $baselineFrame -RegisterCount 1
    Write-Host "      PASS: baseline response is valid. HR$StartRegister=$($baselineRegisters[0])"

    Write-Host "[2/2] Block read: read $Count holding registers from HR$StartRegister"
    $serial.DiscardInBuffer()
    $serial.Write($blockRequest, 0, $blockRequest.Count)
    $blockRaw = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX: $(Format-ByteHex $blockRaw)"
    $blockFrame = [byte[]](Get-ValidReadResponse -Response $blockRaw -ExpectedSlave $SlaveId -ExpectedCount $Count -Label "Block read")
    $blockRegisters = Convert-ResponseToRegisters -Frame $blockFrame -RegisterCount $Count

    if ($blockRegisters[0] -ne $baselineRegisters[0]) {
        throw "Block read FAIL: HR$StartRegister differs from baseline. Baseline=$($baselineRegisters[0]), Block=$($blockRegisters[0])"
    }

    for ($i = 0; $i -lt $Count; $i++) {
        $addr = $StartRegister + $i
        Write-Host ("      HR{0} = {1}" -f $addr, $blockRegisters[$i])
    }
    Write-Host "      PASS: block response length, byte count, CRC, and first register consistency are valid"

    Write-Host ""
    Write-Host "RESULT: PASS"
    exit 0
}
catch {
    Write-Host ""
    Write-Host "RESULT: FAIL"
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
}
