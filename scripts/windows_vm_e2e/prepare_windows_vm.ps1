[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$QemuDirectory,
    [Parameter(Mandatory = $true)][string]$WindowsIso,
    [Parameter(Mandatory = $true)][string]$LabRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9]{16,64}$')][string]$AdminPassword,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9]{16,64}$')][string]$TestUserPassword,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$VmName = "windows-11-e2e",
    [ValidateRange(32, 256)][int]$DiskSizeGigabytes = 50
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function New-AnswerIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if (-not ('ZeonAnswerIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ZeonAnswerIsoWriter {
    public static void Save(object value, string path) {
        IStream stream = (IStream)value;
        byte[] buffer = new byte[64 * 1024];
        IntPtr read = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (var output = new FileStream(path, FileMode.Create,
                                                FileAccess.Write, FileShare.None)) {
                while (true) {
                    Marshal.WriteInt32(read, 0);
                    stream.Read(buffer, buffer.Length, read);
                    int count = Marshal.ReadInt32(read);
                    if (count <= 0) break;
                    output.Write(buffer, 0, count);
                }
            }
        } finally {
            Marshal.FreeHGlobal(read);
        }
    }
}
'@
    }

    $fileSystemImage = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fileSystemImage.FileSystemsToCreate = 3 # ISO9660 | Joliet
    $fileSystemImage.VolumeName = 'ZEON_ANSWER'
    $fileSystemImage.Root.AddTree($SourceDirectory, $false)
    $result = $fileSystemImage.CreateResultImage()
    [ZeonAnswerIsoWriter]::Save($result.ImageStream, $OutputPath)
}

$qemuImg = Join-Path $QemuDirectory "qemu-img.exe"
$firmwareDirectory = Join-Path $QemuDirectory "share"
$firmwareCode = Join-Path $firmwareDirectory "edk2-x86_64-code.fd"
$firmwareTemplate = Join-Path $firmwareDirectory "edk2-i386-vars.fd"
foreach ($required in @($qemuImg, $WindowsIso, $firmwareCode, $firmwareTemplate)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required VM input was not found: $required"
    }
}

$vmDirectory = Join-Path $LabRoot $VmName
$answerDirectory = Join-Path $vmDirectory "answer"
$diskPath = Join-Path $vmDirectory "$VmName.qcow2"
$varsPath = Join-Path $vmDirectory "edk2-vars.fd"
$answerPath = Join-Path $answerDirectory "Autounattend.xml"
$answerIsoPath = Join-Path $vmDirectory "answer.iso"
if (Test-Path -LiteralPath $diskPath) {
    throw "Refusing to overwrite existing VM disk: $diskPath"
}
New-Item -ItemType Directory -Force -Path $answerDirectory | Out-Null
Copy-Item -LiteralPath $firmwareTemplate -Destination $varsPath

$adminPasswordXml = [Security.SecurityElement]::Escape($AdminPassword)
$testPasswordXml = [Security.SecurityElement]::Escape($TestUserPassword)
$unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>ZEON E2E</FullName><Organization>ZEON Test Lab</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>ZEON-E2E</ComputerName><TimeZone>Russian Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>1</ProtectYourPC></OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add"><Name>zeonadmin</Name><DisplayName>ZEON E2E Admin</DisplayName><Group>Administrators</Group><Password><Value>$adminPasswordXml</Value><PlainText>true</PlainText></Password></LocalAccount>
          <LocalAccount wcm:action="add"><Name>zeontest</Name><DisplayName>ZEON E2E Standard User</DisplayName><Group>Users;Remote Management Users</Group><Password><Value>$testPasswordXml</Value><PlainText>true</PlainText></Password></LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <!-- Bootstrap the disposable lab through one administrative logon.
           ZEON itself is installed and exercised later as the standard user. -->
      <AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>zeonadmin</Username><Password><Value>$adminPasswordXml</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -SkipNetworkProfileCheck -Force; Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true; Set-Item WSMan:\localhost\Service\Auth\Basic -Value true; Set-Service WinRM -StartupType Automatic; powercfg.exe /change standby-timeout-ac 0; powercfg.exe /change hibernate-timeout-ac 0"</CommandLine><Description>Enable isolated host-forwarded WinRM</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c echo ready&gt;C:\zeon-e2e-ready.txt</CommandLine><Description>Mark interactive desktop ready</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
[IO.File]::WriteAllText($answerPath, $unattend, [Text.UTF8Encoding]::new($false))
New-AnswerIso -SourceDirectory $answerDirectory -OutputPath $answerIsoPath

& $qemuImg create -f qcow2 $diskPath "${DiskSizeGigabytes}G"
if ($LASTEXITCODE -ne 0) {
    throw "qemu-img failed to create the VM disk."
}

[pscustomobject]@{
    VmDirectory = $vmDirectory
    Disk = $diskPath
    FirmwareCode = $firmwareCode
    FirmwareVars = $varsPath
    AnswerDirectory = $answerDirectory
    AnswerIso = $answerIsoPath
    Iso = (Resolve-Path -LiteralPath $WindowsIso).Path
}
