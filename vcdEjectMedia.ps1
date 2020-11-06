Clear-Host
$vcdServer = "vcd-s1.cloud.vlabs.local"
$vcServer = "vcenter1.cloud.vlabs.local"
$vcUsername = "administrator@vsphere.local"
$vcPassword = "VMware1!"
$apiVer = "32.0"		

#region Bypass untrusted certificates
# --- Work with Untrusted Certificates
if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
$certCallback = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            if(ServicePointManager.ServerCertificateValidationCallback ==null)
            {
                ServicePointManager.ServerCertificateValidationCallback += 
                    delegate
                    (
                        Object obj, 
                        X509Certificate certificate, 
                        X509Chain chain, 
                        SslPolicyErrors errors
                    )
                    {
                        return true;
                    };
            }
        }
    }
"@
    Add-Type $certCallback
 }
[ServerCertificateValidationCallback]::Ignore()

# adding all security protocols
$SecurityProtocols = @(
	[System.Net.SecurityProtocolType]::Ssl3,
	[System.Net.SecurityProtocolType]::Tls,
	[System.Net.SecurityProtocolType]::Tls12
)
[System.Net.ServicePointManager]::SecurityProtocol = $SecurityProtocols -join ","
Write-Host "Adding security protocol Tls,Tls12,Ssl3"

#endregion Bypass untrusted certificates

#Region ConnectvCD
Write-Host "Provide the vCloud Director system admin credential:"
Try {
	$vcdCredential = Get-Credential $null
}
Catch {
	Catch-Error $_.Exception.Message
	Write-Hos "Credentials empty or uncomplete! Exiting"
	break
}

Write-Host "vCloud Director credential accepted."
Write-Host "*************************************************************************"

#Region Connect VC
Connect-VIServer -Server $vcServer -User $vcUsername -Password $vcPassword

# Need to disable ISO lock warning on all VMs excluding NSX vCD edges (vse-*) and NSX controllers (*controller*)
Write-Host "Hiding message cdrom lock from vCenter"
Get-VM | Where-Object {($_.Name -notLike "vse-*") -and ($_.Name -notLike "*controller*")} | New-AdvancedSetting -Name cdrom.showIsoLockWarning -Value "FALSE" -Confirm:$false -Force | Out-Null

# Need to enable auto-answer message on all VMs excluding  NSX vCD edges (vse-*) and NSX controllers (*controller*)
Write-Host "Setting cdrom lock auto-answer"
Get-VM | Where-Object {($_.Name -notLike "vse-*") -and ($_.Name -notLike "*controller*")} | New-AdvancedSetting -Name msg.autoanswer -Value "TRUE" -Confirm:$false -Force | Out-Null

## Configure vCD authentication and prepare rest call
$username =  $vcdCredential.Username + "@system"
$password = ($vcdCredential.GetNetworkCredential()).Password

# Build authorization 
$auth = $username + ':' + $password

# Encode basic authorization for the header
$Encoded = [System.Text.Encoding]::UTF8.GetBytes($auth)
$EncodedPassword = [System.Convert]::ToBase64String($Encoded)

# Define vCD header
$headers = @{
	"Accept" = "application/*+xml;version=$apiVer";
	"Authorization" = "Basic $EncodedPassword";
}

# get a vCD bearer token
$URI = "https://$vcdServer/api/sessions"
$response = Invoke-WebRequest -Method POST -URI $URI -Headers $Headers
$bearerToken =  $response.Headers.'X-VMWARE-VCLOUD-ACCESS-TOKEN'
$headers = @{
	"Accept"="application/*+xml;version=$apiVer"
	"Authorization" = "Bearer $bearerToken"
}

# Connect to vCD via PowerCLI CI cmdlet, hiding default output
Write-Host "Connecting to vCloud Server $vcdServer using CI cmdlet" 
Connect-CIServer -Server $vcdServer -User $vcdCredential.Username -Password $password | Out-Null

#Endregion ConnectvCD

$vcdVMs = Get-CIVM

if ($vcdVMs) {
	foreach ($vm in $vcdVMs) {
		Write-Host "*******************************************************************************************"
		$orgVdc = $vm.OrgVdc.Name
		$URI = $vm.Href	
		$response = Invoke-RestMethod -Uri $URI -Headers $headers -Method GET -WebSession $vcdSession
		$isMounted = $($response.Vm.VirtualHardwareSection.Item | Where-Object {$_.Description -eq "CD/DVD Drive"}).AutomaticAllocation
		$catalogMediaName = $($response.Vm.VirtualHardwareSection.Item | Where-Object {$_.Description -eq "CD/DVD Drive"}).HostResource

		if ($catalogMediaName -ne "") { 
			Write-Host "VM=$($vm.name), OrgVdc=$orgVdc, Media mounted=$isMounted, Catalog name=$catalogMediaName"
		} 
		else { Write-Host "VM=$($vm.name), OrgVdc=$orgVdc, Media mounted=$isMounted, Catalog name=EMPTY(not mounted)" }
		
		# get the list of media beloging to the VM OrgVdc
		$mediaList = Get-Media | Select Name,Status,Catalog,Href,OrgVdc | Where-Object {$_.OrgVdc -like $orgVdc}

		if ($isMounted -and ($catalogMediaName -ne "") -and ($catalogMediaName -ne $null)) {
			# Eject
			foreach ($media in $mediaList) {
				#$myvm = get-vm -name linux-1-Fpcc
				#$myvm | New-AdvancedSetting -Name cdrom.showIsoLockWarning -Value "FALSE" -Confirm:$false
				#$myvm | New-AdvancedSetting -Name msg.autoanswer -Value "TRUE" -Confirm:$false
				if (($vm.OrgVdc -eq $media.OrgVdc) -and ($media.Name -eq $catalogMediaName)) {

					Write-Host "Disconnecting media $($media.Name) for virtual machine $($vm.Name)"

					$vm.ExtensionData.EjectMedia($media.Href)
				}
			# Remove AdvancedSetting
			# $vm | Get-AdvancedSetting -Name cdrom.showIsoLockWarning | Remove-AdvancedSetting -Confirm:$false
			# $vm | Get-AdvancedSetting -Name msg.autoanswer | Remove-AdvancedSetting -Confirm:$false
			}
		}
	}
}
