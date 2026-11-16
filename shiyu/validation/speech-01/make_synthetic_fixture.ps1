$ErrorActionPreference = 'Stop'
$fixtureDirectory = Join-Path $PSScriptRoot 'fixtures'
$waveTarget = Join-Path $fixtureDirectory 'walkthrough-original.wav'
$referencePath = Join-Path $fixtureDirectory 'reference.txt'
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  $synth.SelectVoice('Microsoft Zira Desktop')
  $synth.Rate = 0
  $format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
  $synth.SetOutputToWaveFile($waveTarget, $format)
  $synth.Speak([IO.File]::ReadAllText($referencePath).Trim())
} finally { $synth.Dispose() }
$manifest = [ordered]@{
  schema='shiyu.speech.synthetic-fixture.v1'
  kind='original_synthetic'
  producer='windows-sapi:Microsoft Zira Desktop'
  original=$true
  transformations=@()
  audioFile='walkthrough-original.wav'
  referenceFile='reference.txt'
  audioSha256=(Get-FileHash -LiteralPath $waveTarget -Algorithm SHA256).Hash.ToLowerInvariant()
  referenceSha256=(Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureDirectory 'manifest.local.json') -Encoding utf8
Write-Output 'Original offline synthetic WAV prepared; no playback, microphone, network, or desktop interaction.'
