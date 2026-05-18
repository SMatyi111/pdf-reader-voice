# PDF Reader with Piper TTS - one-shot setup + server
# Run this script (right-click -> Run with PowerShell, or: powershell -ExecutionPolicy Bypass -File start.ps1)

$ErrorActionPreference = "Stop"
# PowerShell 5.1 defaults to TLS 1.0/1.1 which GitHub, HuggingFace, and
# Microsoft's Edge-TTS WebSocket endpoint no longer accept. Enable modern TLS.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$piperDir  = Join-Path $root "piper"
$voicesDir = Join-Path $root "voices"
$piperExe  = Join-Path $piperDir "piper.exe"
$port      = 8910

# ----- One-time setup: download piper.exe -----
if (-not (Test-Path $piperExe)) {
    Write-Host "First-time setup: downloading Piper..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $piperDir -Force | Out-Null
    try {
        $api = Invoke-RestMethod "https://api.github.com/repos/rhasspy/piper/releases/latest" -Headers @{ "User-Agent" = "pdf-reader" }
        $asset = $api.assets | Where-Object { $_.name -like "*windows_amd64*" -and $_.name -like "*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "No Windows Piper asset found in latest release" }
        $zipPath = Join-Path $env:TEMP "piper_download.zip"
        Write-Host "  Downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
        Expand-Archive $zipPath -DestinationPath $piperDir -Force
        Remove-Item $zipPath -Force
        # Piper zip extracts to a "piper" subfolder; flatten if so
        $innerPiper = Join-Path $piperDir "piper"
        if ((Test-Path (Join-Path $innerPiper "piper.exe"))) {
            Get-ChildItem $innerPiper | Move-Item -Destination $piperDir -Force
            Remove-Item $innerPiper -Recurse -Force
        }
        if (-not (Test-Path $piperExe)) { throw "piper.exe not found after extraction" }
        Write-Host "  Piper installed at $piperExe" -ForegroundColor Green
    } catch {
        Write-Host "ERROR downloading Piper: $_" -ForegroundColor Red
        Write-Host "Manual fix: download piper_windows_amd64.zip from https://github.com/rhasspy/piper/releases and extract into:`n  $piperDir" -ForegroundColor Yellow
        exit 1
    }
}

# ----- One-time setup: download default voice model -----
$defaultVoice = "en_US-lessac-medium"
$defaultOnnx  = Join-Path $voicesDir "$defaultVoice.onnx"
$defaultJson  = Join-Path $voicesDir "$defaultVoice.onnx.json"
if (-not (Test-Path $defaultOnnx)) {
    Write-Host "First-time setup: downloading voice model ($defaultVoice, ~63 MB)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $voicesDir -Force | Out-Null
    $base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium"
    try {
        Invoke-WebRequest "$base/$defaultVoice.onnx"      -OutFile $defaultOnnx -UseBasicParsing
        Invoke-WebRequest "$base/$defaultVoice.onnx.json" -OutFile $defaultJson -UseBasicParsing
        Write-Host "  Voice installed." -ForegroundColor Green
    } catch {
        Write-Host "ERROR downloading voice: $_" -ForegroundColor Red
        Write-Host "Manual fix: download the .onnx and .onnx.json from huggingface.co/rhasspy/piper-voices and place in:`n  $voicesDir" -ForegroundColor Yellow
        exit 1
    }
}

# ----- Start HTTP server -----
$listener = [System.Net.HttpListener]::new()
$prefix   = "http://localhost:$port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "Failed to bind to $prefix : $_" -ForegroundColor Red
    Write-Host "Another process may be using port $port. Edit `$port in this script and retry." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "PDF Reader running at $prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C in this window to stop." -ForegroundColor DarkGray
Start-Process $prefix

function Write-Bytes($res, $bytes, $contentType) {
    $res.ContentType = $contentType
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Get-EdgeSecMsGec {
    # Microsoft's edge-tts endpoint requires a dynamic auth token derived from
    # the current 5-minute window combined with the public TrustedClientToken.
    $ticks = (Get-Date).ToFileTimeUtc()
    $ticks = $ticks - ($ticks % 3000000000)
    $combined = "{0}6A5AA1D4EAFF4E9FB37E23D68491D6F4" -f $ticks
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($combined))
        return -join ($hash | ForEach-Object { $_.ToString("X2") })
    } finally { $sha.Dispose() }
}

function _ReadExact($stream, [int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stream.Read($buf, $off, $count - $off)
        if ($n -le 0) { throw "stream closed at $off/$count" }
        $off += $n
    }
    return ,$buf
}

function _SendWsFrame($stream, [int]$opcode, [byte[]]$payload, $rng) {
    $ms = [System.IO.MemoryStream]::new()
    $ms.WriteByte([byte](0x80 -bor $opcode))   # FIN=1
    $len = $payload.Length
    if ($len -lt 126) {
        $ms.WriteByte([byte](0x80 -bor $len))  # MASK=1
    } elseif ($len -lt 65536) {
        $ms.WriteByte([byte](0x80 -bor 126))
        $ms.WriteByte([byte](($len -shr 8) -band 0xFF))
        $ms.WriteByte([byte]($len -band 0xFF))
    } else {
        $ms.WriteByte([byte](0x80 -bor 127))
        for ($i = 7; $i -ge 0; $i--) {
            $ms.WriteByte([byte](($len -shr ($i*8)) -band 0xFF))
        }
    }
    $mask = New-Object byte[] 4
    $rng.GetBytes($mask)
    $ms.Write($mask, 0, 4)
    $masked = New-Object byte[] $len
    for ($i = 0; $i -lt $len; $i++) {
        $masked[$i] = [byte](([int]$payload[$i]) -bxor ([int]$mask[$i % 4]))
    }
    if ($len -gt 0) { $ms.Write($masked, 0, $len) }
    $bytes = $ms.ToArray()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function _ReadWsFrame($stream) {
    $hdr = _ReadExact $stream 2
    $fin    = ($hdr[0] -band 0x80) -ne 0
    $opcode = $hdr[0] -band 0x0F
    $len    = $hdr[1] -band 0x7F
    if ($len -eq 126) {
        $ext = _ReadExact $stream 2
        $len = ([int]$ext[0] -shl 8) -bor [int]$ext[1]
    } elseif ($len -eq 127) {
        $ext = _ReadExact $stream 8
        $len = 0
        for ($i = 0; $i -lt 8; $i++) { $len = ($len * 256) + [int]$ext[$i] }
    }
    $payload = if ($len -gt 0) { _ReadExact $stream $len } else { New-Object byte[] 0 }
    return @{ Fin = $fin; Opcode = $opcode; Payload = $payload }
}

function Synthesize-Edge($text, $voice) {
    # Manual WebSocket over TCP+TLS so we can set User-Agent (PS 5.1's ClientWebSocket can't).
    $TOKEN  = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    $GECVER = "1-131.0.2903.99"
    $GEC    = Get-EdgeSecMsGec
    $connId = [Guid]::NewGuid().ToString("N")
    $reqId  = [Guid]::NewGuid().ToString("N")
    $hostName = "speech.platform.bing.com"
    $reqPath  = "/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=$TOKEN" +
                "&Sec-MS-GEC=$GEC&Sec-MS-GEC-Version=$GECVER&ConnectionId=$connId"

    $tcp = $null; $ssl = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 60000
        $tcp.SendTimeout    = 60000
        $tcp.Connect($hostName, 443)
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $ssl.AuthenticateAsClient($hostName, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)

        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $keyBytes = New-Object byte[] 16
        $rng.GetBytes($keyBytes)
        $secKey = [Convert]::ToBase64String($keyBytes)

        $req = "GET $reqPath HTTP/1.1`r`n" +
               "Host: $hostName`r`n" +
               "Upgrade: websocket`r`n" +
               "Connection: Upgrade`r`n" +
               "Sec-WebSocket-Key: $secKey`r`n" +
               "Sec-WebSocket-Version: 13`r`n" +
               "Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold`r`n" +
               "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0`r`n" +
               "Pragma: no-cache`r`n" +
               "Cache-Control: no-cache`r`n" +
               "Accept-Language: en-US,en;q=0.9`r`n" +
               "`r`n"
        $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($reqBytes, 0, $reqBytes.Length)
        $ssl.Flush()

        # Read status line + headers until \r\n\r\n
        $hb = New-Object System.Collections.Generic.List[byte]
        $one = New-Object byte[] 1
        while ($true) {
            $n = $ssl.Read($one, 0, 1)
            if ($n -le 0) { throw "EOF in headers" }
            $hb.Add($one[0])
            $c = $hb.Count
            if ($c -ge 4 -and $hb[$c-4] -eq 13 -and $hb[$c-3] -eq 10 -and $hb[$c-2] -eq 13 -and $hb[$c-1] -eq 10) { break }
        }
        $headers = [System.Text.Encoding]::ASCII.GetString($hb.ToArray())
        $statusLine = $headers.Split("`r`n")[0]
        if (-not ($statusLine -match "^HTTP/1\.\d 101")) {
            Write-Host "  Edge upgrade rejected: $statusLine" -ForegroundColor Yellow
            return $null
        }

        # Send speech.config + ssml as text WebSocket frames
        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $cfg = "X-Timestamp:$ts`r`nContent-Type:application/json; charset=utf-8`r`nPath:speech.config`r`n`r`n" +
               '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}'
        $esc = $text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace "'",'&apos;' -replace '"','&quot;'
        $ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='$voice'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>$esc</prosody></voice></speak>"
        $ssmlMsg = "X-RequestId:$reqId`r`nContent-Type:application/ssml+xml`r`nX-Timestamp:$ts`r`nPath:ssml`r`n`r`n$ssml"

        _SendWsFrame $ssl 0x1 ([System.Text.Encoding]::UTF8.GetBytes($cfg))     $rng
        _SendWsFrame $ssl 0x1 ([System.Text.Encoding]::UTF8.GetBytes($ssmlMsg)) $rng

        $audioStream = [System.IO.MemoryStream]::new()
        $boundaries  = New-Object System.Collections.Generic.List[hashtable]
        $done = $false
        while (-not $done) {
            $frame = _ReadWsFrame $ssl
            if ($frame.Opcode -eq 0x8) { $done = $true; break }  # close
            if ($frame.Opcode -eq 0x9) {                          # ping → pong
                _SendWsFrame $ssl 0xA $frame.Payload $rng
                continue
            }
            if ($frame.Opcode -eq 0x1) {
                $msgText = [System.Text.Encoding]::UTF8.GetString($frame.Payload)
                if ($msgText.Contains("Path:turn.end")) { $done = $true }
                elseif ($msgText.Contains("Path:audio.metadata")) {
                    $bodyAt = $msgText.IndexOf("`r`n`r`n")
                    if ($bodyAt -gt 0) {
                        try {
                            $body = $msgText.Substring($bodyAt + 4) | ConvertFrom-Json
                            foreach ($md in $body.Metadata) {
                                if ($md.Type -eq "WordBoundary") {
                                    $boundaries.Add(@{
                                        text       = "$($md.Data.text.Text)"
                                        offsetMs   = [double]$md.Data.Offset   / 10000
                                        durationMs = [double]$md.Data.Duration / 10000
                                    })
                                }
                            }
                        } catch {}
                    }
                }
            } elseif ($frame.Opcode -eq 0x2) {
                $b = $frame.Payload
                if ($b.Length -ge 2) {
                    $headerLen = ([int]$b[0] -shl 8) -bor [int]$b[1]
                    $audioStart = 2 + $headerLen
                    if ($audioStart -lt $b.Length) {
                        $audioStream.Write($b, $audioStart, $b.Length - $audioStart)
                    }
                }
            }
        }
        return @{ audio = $audioStream.ToArray(); boundaries = $boundaries }
    } catch {
        Write-Host "  Edge synth error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Dispose() } catch {} }
    }
}

function Synthesize-Text($text, $voice) {
    $modelPath = Join-Path $voicesDir "$voice.onnx"
    if (-not (Test-Path $modelPath)) {
        Write-Host "  voice not found: $modelPath" -ForegroundColor Yellow
        return $null
    }
    $outFile = [System.IO.Path]::Combine($env:TEMP, "piper_" + [System.Guid]::NewGuid().ToString("N") + ".wav")
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName  = $piperExe
        $psi.Arguments = "--model `"$modelPath`" --output_file `"$outFile`""
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $psi.WorkingDirectory       = $piperDir
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($text)
        $proc.StandardInput.Close()
        # Drain stdout/stderr so the process doesn't block on full pipe buffers
        $null = $proc.StandardOutput.ReadToEnd()
        $errOut = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Write-Host "  piper exit $($proc.ExitCode): $errOut" -ForegroundColor Yellow
            return $null
        }
        if (-not (Test-Path $outFile)) {
            Write-Host "  piper produced no output. stderr: $errOut" -ForegroundColor Yellow
            return $null
        }
        return [System.IO.File]::ReadAllBytes($outFile)
    } catch {
        Write-Host "  Synthesize-Text exception: $_" -ForegroundColor Red
        return $null
    } finally {
        if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    }
}

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
    } catch { break }
    $req = $ctx.Request
    $res = $ctx.Response

    $res.Headers["Access-Control-Allow-Origin"]  = "*"
    $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"

    try {
        if ($req.HttpMethod -eq "OPTIONS") {
            $res.StatusCode = 204
            $res.OutputStream.Close()
            continue
        }

        $path = $req.Url.AbsolutePath

        if (($path -eq "/") -or ($path -eq "/index.html") -or ($path -eq "/pdf-reader.html")) {
            $htmlPath = Join-Path $root "pdf-reader.html"
            if (Test-Path $htmlPath) {
                $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
                Write-Bytes $res $bytes "text/html; charset=utf-8"
            } else {
                $res.StatusCode = 404
                $res.OutputStream.Close()
            }
            continue
        }

        if ($path -eq "/voices") {
            $names = @()
            if (Test-Path $voicesDir) {
                $names = Get-ChildItem $voicesDir -Filter "*.onnx" -File | ForEach-Object { $_.BaseName -replace '\.onnx$','' }
            }
            $json = ConvertTo-Json @($names) -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            Write-Bytes $res $bytes "application/json"
            continue
        }

        if (($path -eq "/edge-tts") -and ($req.HttpMethod -eq "POST")) {
            $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
            $body  = $reader.ReadToEnd() | ConvertFrom-Json
            $text  = $body.text
            $voice = if ($body.voice) { $body.voice } else { "en-US-AvaMultilingualNeural" }
            if (-not $text) { $res.StatusCode = 400; $res.OutputStream.Close(); continue }
            $r = Synthesize-Edge $text $voice
            if ($null -eq $r -or $null -eq $r.audio -or $r.audio.Length -eq 0) {
                $res.StatusCode = 502
                $res.OutputStream.Close()
                continue
            }
            $resp = @{
                audio      = [Convert]::ToBase64String($r.audio)
                boundaries = $r.boundaries
            } | ConvertTo-Json -Compress -Depth 4
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
            Write-Bytes $res $bytes "application/json"
            continue
        }

        if (($path -eq "/tts") -and ($req.HttpMethod -eq "POST")) {
            $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd() | ConvertFrom-Json
            $text  = $body.text
            $voice = if ($body.voice) { $body.voice } else { $defaultVoice }
            if (-not $text) {
                $res.StatusCode = 400
                $res.OutputStream.Close()
                continue
            }
            $wav = Synthesize-Text $text $voice
            if ($null -eq $wav) {
                $res.StatusCode = 500
                $res.OutputStream.Close()
                continue
            }
            Write-Bytes $res $wav "audio/wav"
            continue
        }

        $res.StatusCode = 404
        $res.OutputStream.Close()
    } catch {
        Write-Host "Request error: $_" -ForegroundColor Red
        try { $res.StatusCode = 500; $res.OutputStream.Close() } catch {}
    }
}
