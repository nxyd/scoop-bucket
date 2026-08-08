param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string] $Mode,

    [Parameter(Mandatory = $true)]
    [string] $Dir,

    [Parameter(Mandatory = $true)]
    [string] $PersistDir
)

$ErrorActionPreference = 'Stop'
$persistConfig = Join-Path $PersistDir 'config'
$marker = Join-Path $PersistDir '.config-path'

function Remove-ConfigJunction {
    param([string] $Path)

    if (!$Path -or !(Test-Path -LiteralPath $Path)) {
        return
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $localRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
    if (!$fullPath.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        [IO.Directory]::Delete($fullPath)
        $parent = Split-Path $fullPath
        for ($index = 0; $index -lt 2; $index++) {
            if ($parent -and (Test-Path -LiteralPath $parent) -and !(Get-ChildItem -LiteralPath $parent -Force)) {
                [IO.Directory]::Delete($parent)
                $parent = Split-Path $parent
            } else {
                break
            }
        }
    }
}

if (Test-Path -LiteralPath $marker) {
    [IO.File]::ReadAllLines($marker) | ForEach-Object { Remove-ConfigJunction $_ }
}

if ($Mode -eq 'Uninstall') {
    return
}

function Get-AttributeValue {
    param(
        [Reflection.Assembly] $Assembly,
        [string] $TypeName
    )

    $attribute = $Assembly.GetCustomAttributesData() |
        Where-Object { $_.AttributeType.FullName -eq $TypeName } |
        Select-Object -First 1
    if ($attribute) {
        return [string] $attribute.ConstructorArguments[0].Value
    }
}

function ConvertTo-ConfigName {
    param(
        [string] $Value,
        [bool] $LimitSize
    )

    if (!$Value) {
        return $Value
    }

    $result = $Value.Trim()
    [IO.Path]::GetInvalidFileNameChars() | ForEach-Object { $result = $result.Replace($_, '_') }
    $result = $result.Replace(' ', '_')
    if ($LimitSize -and $result.Length -gt 25) {
        $result = $result.Substring(0, 25)
    }
    return $result
}

function ConvertTo-ConfigBase32 {
    param([byte[]] $Bytes)

    $alphabet = 'abcdefghijklmnopqrstuvwxyz012345'
    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $Bytes.Length; $index += 5) {
        [int] $b0 = $Bytes[$index]
        [int] $b1 = $Bytes[$index + 1]
        [int] $b2 = $Bytes[$index + 2]
        [int] $b3 = $Bytes[$index + 3]
        [int] $b4 = $Bytes[$index + 4]
        [void] $builder.Append($alphabet[$b0 -band 31])
        [void] $builder.Append($alphabet[$b1 -band 31])
        [void] $builder.Append($alphabet[$b2 -band 31])
        [void] $builder.Append($alphabet[$b3 -band 31])
        [void] $builder.Append($alphabet[$b4 -band 31])
        [void] $builder.Append($alphabet[(($b0 -band 0xe0) -shr 5) -bor (($b3 -band 0x60) -shr 2)])
        [void] $builder.Append($alphabet[(($b1 -band 0xe0) -shr 5) -bor (($b4 -band 0x60) -shr 2)])
        [void] $builder.Append($alphabet[($b2 -shr 5) -bor (($b3 -band 0x80) -shr 4) -bor (($b4 -band 0x80) -shr 3)])
    }
    return $builder.ToString()
}

function Get-UrlHash {
    param([string] $Url)

    $urlBytes = [Text.Encoding]::UTF8.GetBytes($Url.ToUpperInvariant())
    $stream = New-Object IO.MemoryStream
    try {
        $header = [byte[]] (0, 1, 0, 0, 0, 255, 255, 255, 255, 1, 0, 0, 0, 0, 0, 0, 0, 6, 1, 0, 0, 0)
        $stream.Write($header, 0, $header.Length)
        $length = $urlBytes.Length
        while ($length -ge 128) {
            $stream.WriteByte([byte] (($length -band 127) -bor 128))
            $length = $length -shr 7
        }
        $stream.WriteByte([byte] $length)
        $stream.Write($urlBytes, 0, $urlBytes.Length)
        $stream.WriteByte(11)
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try {
            return ConvertTo-ConfigBase32 ($sha1.ComputeHash($stream.ToArray()))
        } finally {
            $sha1.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$exe = [IO.Path]::GetFullPath((Join-Path $Dir 'PrintPDF.exe'))
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$assemblyName = $assembly.GetName()
if ($assemblyName.GetPublicKey().Length -gt 0) {
    throw 'Strong-name-signed PrintPDF builds are not supported by this persistence script.'
}
$fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
$entryType = $assembly.EntryPoint.DeclaringType
$namespace = $entryType.Namespace
$productName = Get-AttributeValue $assembly 'System.Reflection.AssemblyProductAttribute'
if (!$productName) { $productName = $fileInfo.ProductName }
if (!$productName -and $namespace) { $productName = $namespace.Split('.')[-1] }
if (!$productName) { $productName = $entryType.Name }
$companyName = Get-AttributeValue $assembly 'System.Reflection.AssemblyCompanyAttribute'
if (!$companyName) { $companyName = $fileInfo.CompanyName }
if (!$companyName -and $namespace) { $companyName = $namespace.Split('.')[0] }
if (!$companyName) { $companyName = $productName }
$productVersion = if ($assemblyName.Version) { $assemblyName.Version.ToString() } elseif ($fileInfo.ProductVersion) { $fileInfo.ProductVersion } else { '1.0.0.0' }
$companyName = ConvertTo-ConfigName $companyName $false
$friendlyName = ConvertTo-ConfigName ([IO.Path]::GetFileName($exe)) $true
$evidenceUrl = "file:///$exe"
$urlHash = Get-UrlHash $evidenceUrl
$configDirectory = Join-Path $env:LOCALAPPDATA $companyName
$configDirectory = Join-Path $configDirectory "${friendlyName}_Url_$urlHash"
$configDirectory = Join-Path $configDirectory $productVersion

New-Item $persistConfig -ItemType Directory -Force | Out-Null
$persistFile = Join-Path $persistConfig 'user.config'
if (!(Test-Path -LiteralPath $persistFile)) {
    $candidate = Get-ChildItem $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter 'PrintPDF.exe_*' -ErrorAction SilentlyContinue } |
        ForEach-Object { Get-ChildItem $_.FullName -File -Filter 'user.config' -Recurse -ErrorAction SilentlyContinue } |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -match '<PrintPDF\.Properties\.Settings>' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($candidate) {
        Copy-Item $candidate.FullName $persistFile -Force
    }
}

if (Test-Path -LiteralPath $configDirectory) {
    $item = Get-Item -LiteralPath $configDirectory -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        [IO.Directory]::Delete($configDirectory)
    } else {
        $sourceFile = Join-Path $configDirectory 'user.config'
        if ((Test-Path -LiteralPath $sourceFile) -and (!(Test-Path -LiteralPath $persistFile) -or (Get-Item $sourceFile).LastWriteTimeUtc -gt (Get-Item $persistFile).LastWriteTimeUtc)) {
            Copy-Item $sourceFile $persistFile -Force
        }
        Remove-Item $configDirectory -Recurse -Force
    }
}

New-Item (Split-Path $configDirectory) -ItemType Directory -Force | Out-Null
New-Item $configDirectory -ItemType Junction -Target $persistConfig | Out-Null
[IO.File]::WriteAllText($marker, $configDirectory, (New-Object Text.UTF8Encoding($false)))
