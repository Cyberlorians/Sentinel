1. In the Azure Portal, search for Custom Deployment and "Build your own template in the editor".
2. Paste the content from any of the IsolateMDE Playbooks, hit apply and continue to create on the next step of the deployment.
3. After the playbook has imported we need to configure permissions for the logic app. Disclaimer: the logic app runs as a mananged identity but will need Microsoft Sentinel Responder permissions. To begin, navigate to your new IsolateMDE logic app and go to "Identity" tab. You should see the status is "On". Now click on "Azure Role Assignments".![](https://github.com/Cyberlorians/uploadedimages/blob/main/isolatemdeidentity.png).
4. Lastly, copy the Object (principal) ID from the previous step and put that ID in the below PowerShell script where it states "ENTER OID".
5. Run the PowerShell Script to give proper permissions to the managed identity to ATP enterprise app.

```powershell
$MIGuid = "ENTER OID"
$MI = Get-AzureADServicePrincipal -ObjectId $MIGuid
$MDEAppId = "fc780465-2017-40d4-a0c5-307022471b92"
$PermissionName = "Machine.Isolate"
$MDEServicePrincipal = Get-AzureADServicePrincipal -Filter "appId eq '$MDEAppId'"
$AppRole = $MDEServicePrincipal.AppRoles | Where-Object {$_.Value -eq $PermissionName -and $_.AllowedMemberTypes -contains "Application"}
New-AzureAdServiceAppRoleAssignment -ObjectId $MI.ObjectId -PrincipalId $MI.ObjectId `
-ResourceId $MDEServicePrincipal.ObjectId -Id $AppRole.Id
```
