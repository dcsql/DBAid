<#
.SYNOPSIS
    DBAid Version 6.5.0

    This script is used in conjunction with dbaid.extractor.ps1. 
    
    This script requires PowerShell 5.1 (in PowerShell 7 RijndaelManaged in RSACryptoServiceProvider no longer supports BlockSize=256, but doesn't like/can't use the 128 it asks for either).

    This script is used to:
        - Decrypt the attachment files generated by dbaid.collector.exe.

.DESCRIPTION

    Copyright (C) 2015 Datacom
    GNU GENERAL PUBLIC LICENSE
    Version 3, 29 June 2007

    This script is part of the DBAid toolset.

    This script encrypted attachments generated/sent by the DBAid Collector utility.

    It is intended that the script runs on the SQL Server instance that hosts the DailyChecks database.

.LINK
    DBAid source code: https://github.com/dc-sql/DBAid

.EXAMPLE
    Just edit the variables in the USER VARIABLES TO SET block and run the script.
#>

# Declare function to manage calls to cryptography subsystems.
function Unprotect-Data {
    param (
        [string] $privateKey,
        [System.IO.MemoryStream] $DataStream,
        [string] $filepath
    )

    if ($DataStream.Length -eq 0) {
        throw "No encrypted data was passed to Unprotect-Data!"
    }
    if ([string]::IsNullOrEmpty($privateKey)) {
        throw "No private key was passed to Unprotect-Data!"
    }
    if ([string]::IsNullOrEmpty($filepath)) {
        throw "No filename to write to was passed to Unprotect-Data!"
    }
    if (Test-Path -LiteralPath "$filepath") {
        throw "Filename passed to Unprotect-Data alrady exists!"
    }
	
    $symmetricKey = New-Object System.Security.Cryptography.RijndaelManaged
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider

    try {
        $symmetricKey.KeySize = 256
        $symmetricKey.BlockSize = 256
        $symmetricKey.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $symmetricKey.Padding = [System.Security.Cryptography.PaddingMode]::ISO10126
        $rsa.FromXmlString($privateKey)

        $lenKey = New-Object byte[] 4
        $lenIv = New-Object byte[] 4

        $DataStream.Position = 0
        $DataStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $DataStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null

        $DataStream.Read($lenKey, 0, 3) | Out-Null
        $DataStream.Seek(4, [System.IO.SeekOrigin]::Begin) | Out-Null
        $DataStream.Read($lenIv, 0, 3) | Out-Null

        $lkey = [BitConverter]::ToInt32($lenKey, 0)
        $liv = [BitConverter]::ToInt32($lenIv, 0)
        $startc = 8 + $lkey + $liv

        $keyEncrypted = New-Object byte[] $lkey
        $ivEncrypted = New-Object byte[] $liv

        $DataStream.Seek(8, [System.IO.SeekOrigin]::Begin) | Out-Null
        $DataStream.Read($keyEncrypted, 0, $lkey) | Out-Null
        $DataStream.Seek(8 + $lkey, [System.IO.SeekOrigin]::Begin) | Out-Null
        $DataStream.Read($ivEncrypted, 0, $liv) | Out-Null

        $symmetricKey.Key = $rsa.Decrypt($keyEncrypted, $false)
        $symmetricKey.IV = $rsa.Decrypt($ivEncrypted, $false)

        $fsOut = New-Object System.IO.FileStream($filepath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite)
        $csDecrypt = New-Object System.Security.Cryptography.CryptoStream($DataStream, $symmetricKey.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
        $dsDecompress = New-Object System.IO.Compression.DeflateStream($csDecrypt, [System.IO.Compression.CompressionMode]::Decompress)

        $DataStream.Position = $startc
        $dsDecompress.CopyTo($fsOut)
    }
    finally {
        $symmetricKey.Dispose()
        $rsa.Dispose()
        $fsOut.Dispose()
        $csDecrypt.Dispose()
        $dsDecompress.Dispose()
    }
}

try {
    <# ######## START USER VARIABLES TO SET ######## #>

    $AttachmentFolder = "E:\DBAid_xml\ExtractorWorkingDirectory"
    $ProcessedDirectory = "$AttachmentFolder\processed"
    $Instance = 'SQLSERVERNAME'  # Instance holding database with private key values.
    $Database = 'DATABASENAME'         # Database holding private key values required to decrypt files.

    <# ######## END USER VARIABLES TO SET ######## #>

    <# Build connection string. #>
    [string]$ConnectionString = ''
    [string]$ConnectionString = -join ("Data Source=", $Instance, ';Initial Catalog=', $Database, ';Application Name=DBAid Extractor;Integrated Security=SSPI;')

    <# Connect to SQL Instance. #>
    Write-Host "Connecting to SQL Server holding private keys..." -ForegroundColor Cyan
    try {
        $Connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $Connection.Open()
        $Query = $Connection.CreateCommand()
    }
    catch {
        Write-Host "Error connecting to SQL Server: $_" -ForegroundColor Red
    }

    # Start processing encrypted files.
    Set-Location $AttachmentFolder

    $Files = Get-ChildItem $AttachmentFolder\* -Include *.encrypted

    if ($null -ne $Files) { 
        Write-Host "Starting file processing..." -ForegroundColor Cyan
        foreach ($File in $Files) {
            try {
                $PrivateKeyProc = "EXEC [dbo].[usp_crypto_privatekey] " # Stored procedure to run to retrieve private key value. Database context is set in $ConnectionString.
                $FileFullName = ($File).FullName
                
                # Read contents of encrypted file as byte values into a memory structure to be passed to the decyprion function (it can't work on the file directly).
                $DataStream = [System.IO.MemoryStream]::new()
                $FileBytes = [System.IO.File]::ReadAllBytes($FileFullName)
                $DataStream.Write($FileBytes, 0, $FileBytes.Length)
                $FilePath = ($File.FullName).Replace(".encrypted", ".decrypted.xml")
                
                # Figure out the server name to pass to the procedure that looks up the private key required to decrypt the file. 
                # Server name should be the first word in the file name. Usually delimited by [] but some older versions of DBAid Collector don't do that.
                [string]$ServerName = ($File).Name
                if ($ServerName.Substring(0, 1) -eq "[") {
                    $ServerName = $ServerName.Substring(1);
                    $ServerName = $ServerName.Split(']')[0];
                }
                else {
                    $ServerName = $ServerName.Split('_')[0];
                }
                
                # Complete the stored procedure command.
                $PrivateKeyProc = -join ($PrivateKeyProc, "'",$ServerName,"'")
                
                # Run the stored procedure and store the value in a .NET DataSet object.
                $Query.CommandText = "$PrivateKeyProc"
                $DataSet = New-Object System.Data.DataSet
                $QueryResult = New-Object System.Data.SqlClient.SqlDataAdapter $Query
                $QueryResult.Fill($DataSet) | Out-Null
                $PrivateKeyValue = $DataSet.Tables[0]  # To use actual value [as text], use $PrivateKeyValue.private_key.
                
                # Now pass it all to the decryption function to decrypt and write out to a .xml file with same name.
                Unprotect-Data -privateKey $PrivateKeyValue.private_key -DataStream $DataStream -filepath $FilePath
                
                # Rename the file to indicate it has been processed.
                $FilePath = ($File.Name).Replace(".encrypted", ".encrypted.processed")
                $File | Rename-Item -NewName $FilePath
            }
            catch {
                Write-Host "Error decrypting file: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "No files to decrypt!" -ForegroundColor Cyan
    }

    # Once all the files have been processed, (if there were any files to process), move them to the processed subfolder.
    try {
        if ($null -ne $Files) {
            Write-Host "Moving processed files to $ProcessedDirectory..." -ForegroundColor Cyan
            Move-Item -Path $AttachmentFolder\*.processed -Destination $ProcessedDirectory -Force
        }
    }
    catch {
        Write-Host "Error moving processed files: $_" -ForegroundColor Red
    }
}
catch {
    Write-Host "Error encountered: $_" -ForegroundColor Red
}
finally {
    <# Clean up after myself #>
    If (Test-Path variable:local:AttachmentFolder) { Remove-Variable AttachmentFolder }
    If (Test-Path variable:local:ProcessedDirectory) { Remove-Variable ProcessedDirectory }
    If (Test-Path variable:local:Instance) { Remove-Variable Instance }
    If (Test-Path variable:local:Database) { Remove-Variable Database }
    If (Test-Path variable:local:ConnectionString) { Remove-Variable ConnectionString }
    If (Test-Path variable:local:Connection) { $Connection.Close(); Remove-Variable Connection }
    If (Test-Path variable:local:Query) { Remove-Variable Query }
    If (Test-Path variable:local:Files) { Remove-Variable Files }
    If (Test-Path variable:local:PrivateKeyProc) { Remove-Variable PrivateKeyProc }
    If (Test-Path variable:local:FileFullName) { Remove-Variable FileFullName }
    If (Test-Path variable:local:DataStream) { $DataStream.Dispose(); Remove-Variable DataStream }
    If (Test-Path variable:local:FileBytes) { Remove-Variable FileBytes }
    If (Test-Path variable:local:FilePath) { Remove-Variable FilePath }
    If (Test-Path variable:local:ServerName) { Remove-Variable ServerName }
    If (Test-Path variable:local:PrivateKeyValue) { Remove-Variable PrivateKeyValue }
}
