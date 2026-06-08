param(
    [string]$Port = "COM18",
    [int]$BaudRate = 19200,
    [ValidateSet("None", "Odd", "Even", "Mark", "Space")]
    [string]$Parity = "Even",
    [int]$SlaveId = 1,
    [int]$Register = 100,
    [int]$Count = 1,
    [int]$FragmentDelayMs = 500,
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

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
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

function Assert-ValidReadResponse {
    param(
        [byte[]]$Response,
        [int]$ExpectedSlave,
        [int]$ExpectedCount,
        [string]$Label
    )

    $expectedLength = 5 + (2 * $ExpectedCount)
    $matchStart = -1

    for ($start = 0; $start -le ($Response.Length - $expectedLength); $start++) {
        if ($Response[$start] -ne [byte]$ExpectedSlave -or $Response[$start + 1] -ne 0x03) {
            continue
        }
        if ($Response[$start + 2] -ne [byte](2 * $ExpectedCount)) {
            continue
        }

        [byte[]]$candidate = $Response[$start..($start + $expectedLength - 1)]
        [byte[]]$body = $candidate[0..($candidate.Length - 3)]
        [byte[]]$expectedCrc = Get-ModbusCrc $body
        if ($candidate[$candidate.Length - 2] -eq $expectedCrc[0] -and $candidate[$candidate.Length - 1] -eq $expectedCrc[1]) {
            $matchStart = $start
            break
        }
    }

    if ($matchStart -lt 0) {
        throw "$Label FAIL: no valid Function 03 response found. RX=$(Format-ByteHex $Response)"
    }

    if ($Response.Count -ne $expectedLength) {
        Write-Host "      WARN: valid response found with extra byte(s). Raw RX=$(Format-ByteHex $Response)"
    }
}

$request = [byte[]](New-ReadHoldingRequest -Slave $SlaveId -StartRegister $Register -RegisterCount $Count)
$splitIndex = [Math]::Floor($request.Length / 2)
[byte[]]$firstHalf = $request[0..($splitIndex - 1)]
[byte[]]$secondHalf = $request[$splitIndex..($request.Length - 1)]

Write-Host "ARCH-14 Packet Fragmentation Test"
Write-Host "Port=$Port Baud=$BaudRate Parity=$Parity Slave=$SlaveId Function=03 Register=$Register Count=$Count"
Write-Host "Full request:  $(Format-ByteHex $request)"
Write-Host "First half:    $(Format-ByteHex $firstHalf)"
Write-Host "Second half:   $(Format-ByteHex $secondHalf)"
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

    Write-Host "[1/4] Baseline: send complete Function 03 request"
    $serial.Write($request, 0, $request.Length)
    $baseline = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX: $(Format-ByteHex $baseline)"
    Assert-ValidReadResponse -Response $baseline -ExpectedSlave $SlaveId -ExpectedCount $Count -Label "Baseline"
    Write-Host "      PASS: baseline response is valid"

    Write-Host "[2/4] Fragment: send first half only, then wait $FragmentDelayMs ms"
    $serial.DiscardInBuffer()
    $serial.Write($firstHalf, 0, $firstHalf.Length)
    Start-Sleep -Milliseconds $FragmentDelayMs
    $afterFirstHalf = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX after first half: $(Format-ByteHex $afterFirstHalf)"
    if ($afterFirstHalf.Count -ne 0) {
        throw "Fragment FAIL: MCU responded to incomplete frame."
    }

    Write-Host "[3/4] Fragment: send second half after timeout"
    $serial.Write($secondHalf, 0, $secondHalf.Length)
    $afterSecondHalf = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX after second half: $(Format-ByteHex $afterSecondHalf)"
    if ($afterSecondHalf.Count -ne 0) {
        throw "Fragment FAIL: MCU treated delayed second half as a valid frame or returned unexpected bytes."
    }
    Write-Host "      PASS: delayed split frame was ignored"

    Write-Host "[4/4] Recovery: send complete Function 03 request again"
    $serial.DiscardInBuffer()
    $serial.Write($request, 0, $request.Length)
    $recovery = [byte[]](Read-AvailableBytes $serial)
    Write-Host "      RX: $(Format-ByteHex $recovery)"
    Assert-ValidReadResponse -Response $recovery -ExpectedSlave $SlaveId -ExpectedCount $Count -Label "Recovery"
    Write-Host "      PASS: MCU recovered and still responds to valid request"

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
