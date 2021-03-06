﻿function Get-DigitalSignature
{
    <#
    .SYNOPSIS

    Checks the existence and validity of the Authenticode and Catalog signatures of a specified file.

    .DESCRIPTION

    The catalog signature check/validation used by PowerShell's Get-AuthenticodeSignature is built on undocumented Windows API functions that only exist on Windows 8 and newer Operating Systems.

    Get-DigitalSignature is instead built on the wintrust.dll CryptCATAdmin* and WinVerifyTrust functions. These functions allow us to check both Authenticode (embedded) and Catalog signatures on all Operating Systems compatible with PowerShell.

    Additionally, it is possible for files to be both Authenticode and Catalog signed. Many signature checking applications skip one or the other if the first is found to exist.

    .PARAMETER FilePath

    The path of the file for which a Digital Signature should be checked.

    .NOTES

    Author: Jared Atkinson (@jaredcatkinson)
    License: BSD 3-Clause
    Required Dependencies: PSReflect
    Optional Dependencies: None

    .EXAMPLE
    Get-DigitalSignature -FilePath 'C:\Windows\notepad.exe'

    isAuthenticodeSigned isCatalogSigned
    -------------------- ---------------
                   False            True


    .EXAMPLE
    Get-DigitalSignature -FilePath 'C:\Program Files\AccessData\FTK Imager\ad_globals.dll'

    isAuthenticodeSigned isCatalogSigned
    -------------------- ---------------
                    True           False
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        $FilePath
    )

    # Check if the requested file exists
    if(Test-Path -Path $FilePath)
    {
        # Check for Authenticode Signature (embedded signature)
        $isAuthenticodeSigned = WinVerifyTrust -FilePath $FilePath -Action WINTRUST_ACTION_GENERIC_VERIFY_V2

        # Check for Catalog Signature
        # Get a Handle to the requested file
        $hFile = CreateFile -FileName $FilePath -DesiredAccess GENERIC_READ -ShareMode READ,WRITE -SecurityAttributes ([IntPtr]::Zero) -CreationDisposition OPEN_EXISTING -FlagsAndAttributes FILE_ATTRIBUTE_NORMAL -TemplateHandle ([IntPtr]::Zero)
        
        # We will first check to see if this system has CryptCATAdminAcquireContext2
        # If this function does not exist, then we can assume we are dealing with an older OS version and Catalog V1
        try
        {
            $hModule = LoadLibrary -ModuleName wintrust
            $ProcAddr = GetProcAddress -ModuleHandle $hModule -FunctionName CryptCATAdminAcquireContext2
        }
        # Looks like CryptCATAdminAcquireContext2 is not available, so we can just use CryptCATAdminAcquireContext because we know we are dealing with SHA1 hashes
        catch
        {
            $hCatAdmin = CryptCATAdminAcquireContext -Subsystem DRIVER_ACTION_VERIFY
            $Hash = CryptCATAdminCalcHashFromFileHandle -FileHandle $hFile
            $hCatInfo = CryptCATAdminEnumCatalogFromHash -CatAdminHandle $hCatAdmin -HashPointer $Hash -HashSize $hashSize -PreviousCatInfoHandle ([IntPtr]::Zero)
        }

        # If ProcAddr does not equal 0, then we know that CryptCATAdminAcquireContext2 is available on this system
        if($ProcAddr -ne 0)
        {
            # Newer versions of Windows have two versions of Catalogs (V1 and V2)
            # Catalog V1 uses SHA1 hashes as MemberTags, while Catalog V2 uses SHA256 hashes as MemberTags
            # We are going to first try to lookup using the SHA256 hash and then fail back to a SHA1 hash if needed           
            $hCatAdmin = CryptCATAdminAcquireContext2 -Subsystem DRIVER_ACTION_VERIFY -HashAlgorithm SHA256
            $Hash = CryptCATAdminCalcHashFromFileHandle2 -CatalogHandle $hCatAdmin -FileHandle $hFile
            $hCatInfo = CryptCATAdminEnumCatalogFromHash -CatAdminHandle $hCatAdmin -HashPointer $Hash.HashBytes -HashSize $Hash.HashLength -PreviousCatInfoHandle ([IntPtr]::Zero)

            # If hCatInfo is 0, then we know that we could not find the SHA256 hash in any catalog
            # We can now fall back to SHA1 as our algorithm
            if($hCatInfo -eq 0)
            {
                # Release the Context from the first call to CryptCATAdminAcquireContext2
                CryptCATAdminReleaseContext -CatAdminHandle $hCatAdmin 
                
                # Attempt to lookup the file based on the SHA1 hash
                $hCatAdmin = CryptCATAdminAcquireContext2 -Subsystem DRIVER_ACTION_VERIFY -HashAlgorithm SHA1
                $Hash,$hashSize,$MemberTag = CryptCATAdminCalcHashFromFileHandle2 -CatalogHandle $hCatAdmin -FileHandle $hFile
                $hCatInfo = CryptCATAdminEnumCatalogFromHash -CatAdminHandle $hCatAdmin -HashPointer $Hash.HashBytes -HashSize $Hash.HashLength -PreviousCatInfoHandle ([IntPtr]::Zero)
            }
        }
        
        # If hCatInfo does not equal 0, then we at least found a Catalog file that contains this hash
        if($hCatInfo -ne 0)
        {
            # Lookup the path of the catalog file that hCatInfo indicates
            $CatalogFile = CryptCATCatalogInfoFromContext -CatInfoHandle $hCatInfo
                
            # Verify that the file's catalog signature is indeed trusted
            $isCatalogSigned = WinVerifyTrust -Action WINTRUST_ACTION_GENERIC_VERIFY_V2 -CatalogFilePath $CatalogFile -MemberFilePath $FilePath -MemberTag $Hash.MemberTag
        }
        # If hCatInfo is equal to 0, then we could not find a catalog file containing this file via both SHA256 and SHA1 hash
        else
        {
            # We can deem this file as not signed
            $isCatalogSigned = $false
        }
            
        # Release the Context from the most recent call to CryptCATAdminAcquireContext2
        CryptCATAdminReleaseContext -CatAdminHandle $hCatAdmin

        # Return the results
        $obj = New-Object -TypeName psobject
        $obj | Add-Member -MemberType NoteProperty -Name isAuthenticodeSigned -Value $isAuthenticodeSigned
        $obj | Add-Member -MemberType NoteProperty -Name isCatalogSigned -Value $isCatalogSigned
        
        Write-Output $obj
    }
    # The file does not exist, so throw an error
    else
    {
        throw [System.IO.FileNotFoundException]
    }
}