# Reports whether the type table inside bf6.exe is readable on disk.
# Reads only the file. Changes nothing. Prints four lines.
param([string]$Exe = "I:\Battlefield 6\SP\bf6.exe")
if (-not (Test-Path $Exe)) { Write-Host "not found: $Exe"; exit 1 }
$fs = [System.IO.File]::OpenRead($Exe)
$br = New-Object System.IO.BinaryReader($fs)
$null = $fs.Seek(0x3C, 'Begin'); $pe = $br.ReadUInt32()
$null = $fs.Seek($pe + 6, 'Begin'); $nsec = $br.ReadUInt16()
$null = $fs.Seek($pe + 20, 'Begin'); $optsz = $br.ReadUInt16()
$so = $pe + 24 + $optsz
$off = 0; $size = 0
for ($i = 0; $i -lt $nsec; $i++) {
  $null = $fs.Seek($so + $i * 40, 'Begin')
  $nm = ([System.Text.Encoding]::ASCII.GetString($br.ReadBytes(8))).Trim([char]0)
  $null = $fs.Seek($so + $i * 40 + 16, 'Begin')
  $rawsz = $br.ReadUInt32(); $rawoff = $br.ReadUInt32()
  if ($nm -eq 'typeinfo') { $off = $rawoff; $size = $rawsz }
}
Write-Host ("file size        {0}" -f $fs.Length)
if ($size -eq 0) { Write-Host "typeinfo section NOT PRESENT"; $fs.Close(); exit 0 }
Write-Host ("typeinfo section {0} bytes at offset {1}" -f $size, $off)
$n = [Math]::Min(1048576, $size)
$null = $fs.Seek($off, 'Begin'); $buf = $br.ReadBytes($n)
$counts = New-Object 'int[]' 256
foreach ($b in $buf) { $counts[$b]++ }
$H = 0.0
foreach ($c in $counts) { if ($c -gt 0) { $p = $c / $n; $H -= $p * [Math]::Log($p, 2) } }
$zero = ($buf | Where-Object { $_ -eq 0 }).Count
Write-Host ("entropy          {0:N2} bits/byte over {1} bytes" -f $H, $n)
Write-Host ("zero bytes       {0:N1}%" -f (100.0 * $zero / $n))
if ($H -gt 7.5) { Write-Host "VERDICT: encrypted or compressed on disk, unreadable" }
else { Write-Host "VERDICT: plain data, readable" }
$fs.Close()
