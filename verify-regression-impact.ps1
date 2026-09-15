<#
.SYNOPSIS
    Produce a deterministic, read-only regression-impact checklist from changed files.

.DESCRIPTION
    Finds existing tests with filename/content relationships to changed source files,
    and flags configuration changes for manual smoke review. A related test is not a
    coverage, adequacy, safety, or regression-protection conclusion. Suggested package
    commands are displayed only; this script never executes them or changes the repo.

.PARAMETER BaseRef
    Compare BaseRef..HEAD instead of the current working tree.

.PARAMETER ChangedFile
    One or more explicit repository-relative changed file paths.

.PARAMETER IncludeUntracked
    Include untracked files when scanning the working tree.

.PARAMETER NoGit
    Do not call Git; useful for an empty/explicit offline check.

.PARAMETER OutputFormat
    Text or Json.

.PARAMETER RedactPaths
    Replace the repository root in machine-readable output with <REPOSITORY>.

.EXAMPLE
    .\verify-regression-impact.ps1

.EXAMPLE
    .\verify-regression-impact.ps1 -BaseRef HEAD~1
#>
[CmdletBinding()]
param(
    [string] $RepositoryPath = (Get-Location).Path,
    [string] $BaseRef,
    [string[]] $ChangedFile,
    [switch] $IncludeUntracked,
    [switch] $NoGit,
    [ValidateSet('Text', 'Json')]
    [string] $OutputFormat = 'Text',
    [switch] $RedactPaths,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $Base)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path -Path $Base -ChildPath $Path))
}

function Get-RelativePathText {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] [string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullRoot.Length).Replace('\', '/')
    }
    return $fullPath.Replace('\', '/')
}

function Get-GitLines {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments, [Parameter(Mandatory = $true)] [string] $Root)
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = 'git'
    $processInfo.WorkingDirectory = $Root
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $allArguments = @('-C', $Root) + $Arguments
    $quotedArguments = foreach ($argument in $allArguments) {
        $value = [string]$argument
        '"' + $value.Replace('"', '\"') + '"'
    }
    $processInfo.Arguments = $quotedArguments -join ' '
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $null = $process.Start()
    $output = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) { throw "git command failed: $(if ($stderr) { $stderr } else { $output })" }
    if ([string]::IsNullOrWhiteSpace($output)) { return @() }
    return @($output -split '\r?\n')
}

function Get-ChangedFilesFromGit {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [AllowEmptyString()] [string] $Range,
        [switch] $IncludeUntracked
    )
    $records = New-Object System.Collections.Generic.List[object]
    $diffArguments = @('diff', '--name-status', '--no-renames')
    if (-not [string]::IsNullOrWhiteSpace($Range)) { $diffArguments += "$Range..HEAD" }
    foreach ($line in @(Get-GitLines -Arguments $diffArguments -Root $Root)) {
        $parts = $line -split ([char]9), 2
        if ($parts.Count -ge 2) { $records.Add([pscustomobject]@{ status = $parts[0]; path = $parts[1] }) }
    }
    foreach ($line in @(Get-GitLines -Arguments @('diff', '--cached', '--name-status', '--no-renames') -Root $Root)) {
        $parts = $line -split ([char]9), 2
        if ($parts.Count -ge 2) { $records.Add([pscustomobject]@{ status = "INDEX_$($parts[0])"; path = $parts[1] }) }
    }
    if ($IncludeUntracked -and [string]::IsNullOrWhiteSpace($Range)) {
        foreach ($line in @(Get-GitLines -Arguments @('status', '--short', '--untracked-files=all') -Root $Root)) {
            if ($line -match '^\?\?\s+(.+)$') { $records.Add([pscustomobject]@{ status = 'UNTRACKED'; path = $Matches[1] }) }
        }
    }
    return $records
}

function Get-PathKind {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $normalized = $Path.Replace('\', '/')
    $leaf = Split-Path -Leaf $Path
    $extension = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if ($normalized -match '(^|/)(test|tests|__tests__)/' -or $leaf -match '\.(test|spec)\.') { return 'TEST' }
    if ($normalized -match '(^|/)private-data(/|$)') { return 'DATA' }
    if ($extension -in @('.md', '.txt', '.rst', '.adoc')) { return 'DOCS_ONLY' }
    if ($extension -in @('.json', '.yaml', '.yml', '.toml', '.ini', '.cfg', '.xml', '.config')) { return 'CONFIG_ONLY' }
    if ($extension -in @('.js', '.cjs', '.mjs', '.ts', '.tsx', '.jsx', '.ps1', '.psm1', '.py', '.java', '.kt', '.kts', '.cs', '.go', '.rs', '.sh', '.cmd', '.bat')) { return 'SOURCE' }
    return 'OTHER'
}

function Get-TestFiles {
    param([Parameter(Mandatory = $true)] [string] $Root)
    $files = New-Object System.Collections.Generic.List[string]
    $testCodeExtensions = @('.js', '.cjs', '.mjs', '.ts', '.tsx', '.jsx', '.py', '.ps1', '.psm1', '.java', '.kt', '.kts', '.cs', '.go', '.rs', '.sh', '.cmd', '.bat')
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        $relative = Get-RelativePathText -Path $file.FullName -Root $Root
        if ($relative -match '(^|/)(node_modules|\.git|\.claude|private-data)/') { continue }
        $inTestPath = $relative -match '(^|/)(test|tests|__tests__)/'
        $hasTestName = $file.Name -match '\.(test|spec)\.'
        if (($inTestPath -or $hasTestName) -and $file.Extension.ToLowerInvariant() -in $testCodeExtensions) { $files.Add($file.FullName) }
    }
    return $files
}

function Get-PathTokens {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $leaf = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path))
    $leaf = $leaf -replace '\.(test|spec)$', ''
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($token in ($leaf -split '[-_.]')) {
        if ($token.Length -ge 3 -and $token -notin @('index', 'main', 'test')) { $tokens.Add($token.ToLowerInvariant()) }
    }
    if ($tokens.Count -eq 0 -and $leaf.Length -ge 3) { $tokens.Add($leaf.ToLowerInvariant()) }
    return $tokens
}

function Get-RelatedTests {
    param(
        [Parameter(Mandatory = $true)] [string] $ChangedPath,
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string[]] $TestFiles
    )
    $tokens = @(Get-PathTokens -Path $ChangedPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $ChangedPath)).ToLowerInvariant()
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($testFile in $TestFiles) {
        $testRelative = Get-RelativePathText -Path $testFile -Root $Root
        $testName = (Split-Path -Leaf $testFile).ToLowerInvariant()
        $evidence = New-Object System.Collections.Generic.List[string]
        foreach ($token in $tokens) {
            if ($testName.Contains($token) -or $testRelative.ToLowerInvariant().Contains($token)) { $evidence.Add("filename token '$token'") }
        }
        try {
            $content = [IO.File]::ReadAllText($testFile).ToLowerInvariant()
            if ($content.Contains($baseName) -or $content.Contains($ChangedPath.Replace('\', '/').ToLowerInvariant())) { $evidence.Add('test content references changed basename/path') }
        } catch {
            $evidence.Add('test file unreadable')
        }
        if ($evidence.Count -gt 0) {
            $matches.Add([pscustomobject]@{ path = $testRelative; evidence = @($evidence | Select-Object -Unique) })
        }
    }
    return @($matches | Sort-Object path | Select-Object -First 8)
}

$invocationRoot = (Get-Location).Path
$root = Get-FullPath -Path $RepositoryPath -Base $invocationRoot
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Repository path does not exist: $root" }
$changedFileValues = @()
if ($null -ne $ChangedFile) { $changedFileValues = @($ChangedFile) }

$changedRecords = New-Object System.Collections.Generic.List[object]
if ($changedFileValues.Count -gt 0) {
    foreach ($path in $changedFileValues) { $changedRecords.Add([pscustomobject]@{ status = 'EXPLICIT'; path = $path.Replace('\', '/') }) }
} elseif (-not $NoGit) {
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git was not found. Use -ChangedFile or -NoGit for explicit offline input.' }
    foreach ($record in @(Get-ChangedFilesFromGit -Root $root -Range $BaseRef -IncludeUntracked:$IncludeUntracked)) { $changedRecords.Add($record) }
}

$uniqueRecords = @($changedRecords | Group-Object -Property path | ForEach-Object { $_.Group[0] } | Sort-Object path)
$testFiles = @(Get-TestFiles -Root $root)
$packageScripts = @()
$packagePath = Join-Path $root 'package.json'
if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
    try {
        $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
        if ($null -ne $package.scripts) { $packageScripts = @($package.scripts.PSObject.Properties | Where-Object { $_.Name -match '(?i)test|check|lint' } | ForEach-Object { $_.Name }) }
    } catch { $packageScripts = @() }
}

$items = New-Object System.Collections.Generic.List[object]
foreach ($record in $uniqueRecords) {
    $relativePath = $record.path.Replace('\', '/')
    $kind = Get-PathKind -Path $relativePath
    $area = ($relativePath -split '/')[0]
    $relatedTests = @()
    $state = 'UNKNOWN'
    $smoke = $false
    $reason = ''
    $evidence = New-Object System.Collections.Generic.List[string]
    switch ($kind) {
        'SOURCE' {
            $relatedTests = @(Get-RelatedTests -ChangedPath $relativePath -Root $root -TestFiles $testFiles)
            $smoke = $true
            if ($relatedTests.Count -gt 0) {
                $state = 'RELATED_TEST_FOUND'
                $reason = 'Existing test filename/content has a deterministic relation; this is not a coverage measurement.'
                $evidence.Add('existing test filename/content relationship')
            } else {
                $state = 'NO_RELATED_TEST_FOUND'
                $reason = 'No deterministic filename/content relation to an existing test was found.'
                $evidence.Add("searched $($testFiles.Count) discovered test files")
            }
        }
        'TEST' {
            $state = 'RELATED_TEST_FOUND'
            $reason = 'The changed file is itself classified as a test; execution and behavior still require review.'
            $evidence.Add('changed path matches the test path/name rule')
        }
        'CONFIG_ONLY' {
            $state = 'MANUAL_SMOKE_RECOMMENDED'
            $smoke = $true
            $reason = 'Configuration changes can affect runtime paths without a directly named test.'
            $evidence.Add('changed path matches the configuration extension rule')
        }
        'DOCS_ONLY' {
            $reason = 'Documentation-only change; no execution coverage claim is made.'
            $evidence.Add('changed path matches the documentation extension rule')
        }
        'DATA' {
            $reason = 'Data/private-data path; content was not read and no test coverage is inferred.'
            $evidence.Add('changed path matches the private-data path rule')
        }
        default {
            $reason = 'File kind is outside the deterministic source/test/config rules.'
            $evidence.Add('no deterministic file-kind rule matched')
        }
    }
    $items.Add([pscustomobject]@{
        changedFile = $relativePath
        status = [string]$record.status
        likelyAffectedArea = $area
        fileKind = $kind
        classification = $state
        relatedTests = $relatedTests
        manualSmokeRecommended = $smoke
        evidence = @($evidence)
        reason = $reason
    })
}

$suggestedCommands = New-Object System.Collections.Generic.List[string]
foreach ($scriptName in $packageScripts) { $suggestedCommands.Add("npm run $scriptName") }
if ($suggestedCommands.Count -eq 0) { $suggestedCommands.Add('UNKNOWN: no package test/check/lint script discovered') }

$outputRoot = $root
if ($RedactPaths) { $outputRoot = '<REPOSITORY>' }
$result = [ordered]@{}
$result.schemaVersion = 1
$result.repository = $outputRoot
$result.baseRef = if ([string]::IsNullOrWhiteSpace($BaseRef)) { $null } else { $BaseRef }
$result.inputMode = if ($changedFileValues.Count -gt 0) { 'EXPLICIT_CHANGED_FILES' } elseif ($NoGit) { 'NO_GIT_EMPTY_OR_EXPLICIT' } else { 'GIT_DIFF' }
$result.changedFileCount = $items.Count
$result.testFileCount = $testFiles.Count
$result.packageTestCommands = @($suggestedCommands)
$result.items = $items.ToArray()

if ($OutputFormat -eq 'Json') {
    $rendered = $result | ConvertTo-Json -Depth 10
} else {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Regression impact verifier (deterministic, read-only)')
    $lines.Add("Changed files: $($items.Count)")
    $lines.Add("Existing test files discovered: $($testFiles.Count)")
    $lines.Add('')
    if ($items.Count -eq 0) {
        $lines.Add('No changed files detected. No regression conclusion is made.')
    } else {
        foreach ($item in $items) {
            $lines.Add("[$($item.classification)] $($item.changedFile) area=$($item.likelyAffectedArea) manualSmoke=$($item.manualSmokeRecommended)")
            if (@($item.relatedTests).Count -gt 0) { $lines.Add('  related tests: ' + ((@($item.relatedTests) | ForEach-Object { $_.path }) -join ', ')) }
            $lines.Add('  evidence: ' + ((@($item.evidence)) -join '; '))
            $lines.Add("  reason: $($item.reason)")
        }
    }
    $lines.Add('')
    $lines.Add('Suggested existing commands (not executed):')
    foreach ($command in $suggestedCommands) { $lines.Add("  $command") }
    $rendered = $lines -join [Environment]::NewLine
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Set-Content -LiteralPath $OutputPath -Value $rendered -Encoding UTF8 }
Write-Output $rendered
