param([Parameter(Mandatory=$true)][int]$Run)

# Build number to dotted version: 122 -> 1.2.2.
$padded = $Run.ToString("D3")
Write-Output (($padded.ToCharArray()) -join '.')
