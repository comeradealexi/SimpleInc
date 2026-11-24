# Bad argc / usage text
param($Suite)

function Invoke-SimpleIncRaw {
    param([string]$Exe, [string[]]$Args)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Args | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

Clear-EnvFakeKnobs
$exe = $Suite.SimpleIncExe

$cases = @(
    @{ Name = 'no-args'; Args = @() },
    @{ Name = 'one-arg'; Args = @('C:\tracker') },
    @{ Name = 'two-args'; Args = @('C:\tracker', 'C:\cache') }
)

foreach ($c in $cases) {
    Write-ValLog "argc case: $($c.Name)"
    $r = Invoke-SimpleIncRaw -Exe $exe -Args $c.Args
    Assert-ExitCode -1 $r.ExitCode "usage exit for $($c.Name)"
    Assert-True ($r.StdOut -match 'Arg 0:') "usage mentions Arg 0 for $($c.Name)"
    Assert-True ($r.StdOut -match 'Arg 1:') "usage mentions Arg 1 for $($c.Name)"
    Assert-True ($r.StdOut -match 'Arg 2:') "usage mentions Arg 2 for $($c.Name)"
    # Newlines between args (critique: PrintUsage was one run-on line)
    $lines = @($r.StdOut -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    Assert-True ($lines.Count -ge 3) "PrintUsage should emit multiple lines (got $($lines.Count)): $($r.StdOut)"
}

Write-ValLog 'Test-ArgcUsage passed'
