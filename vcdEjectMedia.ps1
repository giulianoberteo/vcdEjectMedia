cls
$vcdServer = "vcdcell01"
$apiVer = "5.5"		

#region Bypass untrusted certificates
# --- Work with Untrusted Certificates
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
	[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
	Write-Host "Added TrustAllCertsPolicy policy"
    }
	else {
		Write-Host "TrustAllCertsPolicy policy already installed."
    }
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
	"Accept"="application/*+xml;version=$apiVer"
	"Authorization"="Basic $EncodedPassword"
}
# get a vCD token. The token is stored inside $vcdSession var which is later passed as -WebSession
$URI = "https://$vcdServer/api/sessions"
$response = Invoke-RestMethod -Method POST -URI $URI -Headers $Headers -Session vcdSession

# Connect to vCD via PowerCLI CI cmdlet
Write-Host "Connecting to vCloud Server $vcdServer using CI cmdlet" 
Connect-CIServer -Server $vcdServer -User $vcdCredential.Username -Password $password

#Endregion ConnectvCD

$vcdVMs = Get-CIVM

if ($vcdVMs) {
	foreach ($vm in $vcdVMs) {
		Write-Host "*******************************************************************************************"
		$orgVdc = $vm.OrgVdc.Name
		$URI = $vm.Href
		$response = Invoke-RestMethod -Uri $URI -Headers $headers -Method GET -WebSession $vcdSession
		$isMounted = $($response.Vm.VirtualHardwareSection.Item | where {$_.Description -eq "CD/DVD Drive"}).AutomaticAllocation
		$catalogMediaName = $($response.Vm.VirtualHardwareSection.Item | where {$_.Description -eq "CD/DVD Drive"}).HostResource
		if ($catalogMediaName -ne "") { 
			Write-Host "VM=$($vm.name), OrgVdc=$orgVdc, Media mounted=$isMounted, Catalog name=$catalogMediaName"
		} 
		else { Write-Host "VM=$($vm.name), OrgVdc=$orgVdc, Media mounted=$isMounted, Catalog name=EMPTY(not mounted)" }
		
		# get the list of media beloging to the VM OrgVdc
		$mediaList = Get-Media | Select Name,Status,Catalog,Href,OrgVdc | Where-Object {$_.OrgVdc -like $orgVdc}
		if ($isMounted -and ($catalogMediaName -ne "") -and ($catalogMediaName -ne $null)) {
			# Eject
			foreach ($media in $mediaList){
				if (($vm.OrgVdc -eq $media.OrgVdc) -and ($media.Name -eq $catalogMediaName)) {
					Write-Host "Disconnecting media $($media.Name) for virtual machine $($vm.Name)"
					$vm.ExtensionData.EjectMedia($media.Href)
				}
			}
		}
	}
}
