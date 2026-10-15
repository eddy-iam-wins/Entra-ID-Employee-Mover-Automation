# ============================================================
# Microsoft Entra ID Employee Mover Automation
# ============================================================
# Purpose:
# Simulates the Mover stage of the JML identity lifecycle.
# Processes an employee department/role change using
# PowerShell and Microsoft Graph.
# ============================================================


# ============================================================
# Microsoft Graph Authentication
# ============================================================

Write-Host ""
Write-Host "Connecting to Microsoft Graph..."

Connect-MgGraph -Scopes `
    "User.ReadWrite.All", `
    "Group.Read.All", `
    "EntitlementManagement.ReadWrite.All"

Write-Host "Connected to Microsoft Graph."


# ============================================================
# Import HR Mover Input
# ============================================================

Write-Host ""
Write-Host "Importing HR mover data..."

$InputFile = Join-Path $PSScriptRoot "..\Input\Mover-Input.csv"

if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: Mover input file could not be found."
    exit
}

$MoverData = Import-Csv $InputFile

if (-not $MoverData) {
    Write-Host "ERROR: Mover input file contains no employee records."
    exit
}

Write-Host "Mover data imported successfully."


# ============================================================
# Process Employee Mover Record
# ============================================================

foreach ($Employee in $MoverData) {

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Processing Employee Mover"
    Write-Host "============================================"

    Write-Host "User Principal Name: $($Employee.UserPrincipalName)"
    Write-Host "Current Department:  $($Employee.CurrentDepartment)"
    Write-Host "New Department:      $($Employee.NewDepartment)"
    Write-Host "Current Job Title:   $($Employee.CurrentJobTitle)"
    Write-Host "New Job Title:       $($Employee.NewJobTitle)"


    # ========================================================
    # Locate Employee in Microsoft Entra ID
    # ========================================================

    Write-Host ""
    Write-Host "Locating employee in Microsoft Entra ID..."

    try {

        $EntraUser = Get-MgUser `
            -UserId $Employee.UserPrincipalName `
            -Property Id,DisplayName,UserPrincipalName,Department,JobTitle,AccountEnabled `
            -ErrorAction Stop

    }
    catch {

        Write-Host "ERROR: Employee could not be found in Microsoft Entra ID."
        Write-Host "Mover process stopped."
        continue

    }

    Write-Host "Employee located successfully."
    Write-Host ""
    Write-Host "Display Name: $($EntraUser.DisplayName)"
    Write-Host "Department:   $($EntraUser.Department)"
    Write-Host "Job Title:    $($EntraUser.JobTitle)"


    # ========================================================
    # Validate Current Employee State
    # ========================================================

    Write-Host ""
    Write-Host "Validating current employee state..."

    $IsPreMoveState =
        ($EntraUser.Department -eq $Employee.CurrentDepartment) -and
        ($EntraUser.JobTitle -eq $Employee.CurrentJobTitle)

    $IsTargetState =
        ($EntraUser.Department -eq $Employee.NewDepartment) -and
        ($EntraUser.JobTitle -eq $Employee.NewJobTitle)


    if ($IsPreMoveState) {

        Write-Host "PASS: Employee is in the expected pre-move state."
        Write-Host "Identity attribute update is required."

        $IdentityUpdateRequired = $true

    }
    elseif ($IsTargetState) {

        Write-Host "PASS: Employee is already in the target identity state."
        Write-Host "Identity attribute update has already been completed."
        Write-Host "Mover workflow will continue with access processing."

        $IdentityUpdateRequired = $false

    }
    else {

        Write-Host "VALIDATION FAILED: Employee identity is in an unexpected state."
        Write-Host ""
        Write-Host "Actual Department: $($EntraUser.Department)"
        Write-Host "Actual Job Title:  $($EntraUser.JobTitle)"
        Write-Host ""
        Write-Host "Expected Pre-Move:"
        Write-Host "Department: $($Employee.CurrentDepartment)"
        Write-Host "Job Title:  $($Employee.CurrentJobTitle)"
        Write-Host ""
        Write-Host "Expected Target:"
        Write-Host "Department: $($Employee.NewDepartment)"
        Write-Host "Job Title:  $($Employee.NewJobTitle)"
        Write-Host ""
        Write-Host "Mover process stopped to prevent an unintended change."

        continue

    }



    # ========================================================
    # Pre-Move Access Discovery
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Pre-Move Access Discovery"
    Write-Host "============================================"


    # ========================================================
    # Verify All Employees Baseline Access
    # ========================================================

    Write-Host ""
    Write-Host "Checking All Employees baseline access..."

    try {

        $AllEmployeesGroup = Get-MgGroup `
            -Filter "displayName eq 'All Employees'" `
            -ErrorAction Stop

        if (-not $AllEmployeesGroup) {
            Write-Host "ERROR: All Employees security group could not be found."
            continue
        }

        $AllEmployeesMembers = Get-MgGroupMember `
            -GroupId $AllEmployeesGroup.Id `
            -All `
            -ErrorAction Stop

        $IsAllEmployeesMember = $AllEmployeesMembers.Id -contains $EntraUser.Id

        if ($IsAllEmployeesMember) {

            Write-Host "PASS: $($EntraUser.DisplayName) is a member of All Employees."
            Write-Host "Baseline access will be retained."

        }
        else {

          Write-Host "WARNING: $($EntraUser.DisplayName) is not a member of All Employees."

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify All Employees membership."
        Write-Host $_.Exception.Message
        continue

    }


    # ========================================================
    # Verify HR Operations Access Package Assignment
    # ========================================================

    Write-Host ""
    Write-Host "Checking HR Operations Access Package assignment..."

    try {

        $HrAccessPackage = Get-MgEntitlementManagementAccessPackage `
            -Filter "displayName eq 'HR Operations Access Package'" `
            -ErrorAction Stop

        if (-not $HrAccessPackage) {

            Write-Host "ERROR: HR Operations Access Package could not be found."
            continue

        }

        Write-Host "HR Operations Access Package located."

        $AssignmentFilter = "accessPackage/id eq '$($HrAccessPackage.Id)' and state eq 'Delivered' and target/objectId eq '$($EntraUser.Id)'"

        $HrAccessPackageAssignment = Get-MgEntitlementManagementAssignment `
            -Filter $AssignmentFilter `
            -ExpandProperty target,accessPackage `
            -ErrorAction Stop

        if ($HrAccessPackageAssignment) {

            Write-Host "PASS: $($EntraUser.DisplayName) has a delivered HR Operations Access Package assignment."
            $HasHrAccessPackage = $true

        }
        else {

            Write-Host "WARNING: No delivered HR Operations Access Package assignment was found."
            $HasHrAccessPackage = $false

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify HR Operations Access Package assignment."
        Write-Host $_.Exception.Message
        continue

    }


    # ========================================================
    # Display Current Access Summary
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "CURRENT ACCESS DISCOVERY"
    Write-Host "============================================"

    Write-Host "Employee:   $($EntraUser.DisplayName)"
    Write-Host "Department: $($EntraUser.Department)"
    Write-Host "Job Title:  $($EntraUser.JobTitle)"
    Write-Host ""

    if ($IsAllEmployeesMember) {
        Write-Host "[PASS] All Employees - Present / Retain"
    }
    else {
        Write-Host "[WARN] All Employees - Not Present"
    }

    if ($HasHrAccessPackage) {
        Write-Host "[PASS] HR Operations Access Package - Delivered / Remove During Move"
    }
    else {
        Write-Host "[WARN] HR Operations Access Package - Not Found"
    }

    Write-Host ""
    Write-Host "Current access discovery completed."




    # ========================================================
    # Generate Pre-Move Report
    # ========================================================

    Write-Host ""
    Write-Host "Generating pre-move report..."

    $ReportPath = Join-Path $PSScriptRoot "..\Reports\Mover-PreChange-Report.csv"

    $PreMoveReport = [PSCustomObject]@{

        Timestamp                 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DisplayName               = $EntraUser.DisplayName
        UserPrincipalName         = $EntraUser.UserPrincipalName
        Department                = $EntraUser.Department
        JobTitle                  = $EntraUser.JobTitle
        AccountEnabled            = $EntraUser.AccountEnabled
        AllEmployeesAccess        = $IsAllEmployeesMember
        HrOperationsAccessPackage = $HasHrAccessPackage
        PlannedDepartment         = $Employee.NewDepartment
        PlannedJobTitle           = $Employee.NewJobTitle

    }

    if (-not (Test-Path $ReportPath)) {

        $PreMoveReport |
            Export-Csv `
                -Path $ReportPath `
                -NoTypeInformation

        Write-Host "Pre-move report generated successfully."
        Write-Host "Report: $ReportPath"

    }
    else {

        Write-Host "Pre-move report already exists."
        Write-Host "Existing pre-change evidence will be preserved."
        Write-Host "Report: $ReportPath"

    }



    if ($IdentityUpdateRequired) {

    # ========================================================
    # Update Employee Identity Attributes
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Updating Employee Identity"
    Write-Host "============================================"

    Write-Host ""
    Write-Host "Updating $($EntraUser.DisplayName)'s department and job title..."

    try {

        Update-MgUser `
            -UserId $EntraUser.Id `
            -Department $Employee.NewDepartment `
            -JobTitle $Employee.NewJobTitle `
            -ErrorAction Stop

        Write-Host "Identity attributes updated successfully."

    }
    catch {

        Write-Host "ERROR: Unable to update employee identity attributes."
        Write-Host $_.Exception.Message
        Write-Host "Mover process stopped."
        continue

    }


    # ========================================================
    # Verify Identity Attribute Update
    # ========================================================

    Write-Host ""
    Write-Host "Verifying identity attribute changes..."

    try {

        $UpdatedUser = Get-MgUser `
            -UserId $Employee.UserPrincipalName `
            -Property Id,DisplayName,UserPrincipalName,Department,JobTitle,AccountEnabled `
            -ErrorAction Stop

        if (
            $UpdatedUser.Department -eq $Employee.NewDepartment -and
            $UpdatedUser.JobTitle -eq $Employee.NewJobTitle
        ) {

            Write-Host "PASS: Identity attribute update verified."
            Write-Host ""
            Write-Host "Department: $($EntraUser.Department) -> $($UpdatedUser.Department)"
            Write-Host "Job Title:  $($EntraUser.JobTitle) -> $($UpdatedUser.JobTitle)"

        }
        else {

            Write-Host "ERROR: Identity attribute verification failed."
            Write-Host "Mover process stopped."
            continue

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify updated employee identity."
        Write-Host $_.Exception.Message
        continue

    }


    }
    else {

        Write-Host ""
        Write-Host "============================================"
        Write-Host "Employee Identity Update"
        Write-Host "============================================"
        Write-Host ""
        Write-Host "SKIP: $($EntraUser.DisplayName) is already in the target identity state."
        Write-Host "Department: $($EntraUser.Department)"
        Write-Host "Job Title:  $($EntraUser.JobTitle)"
        Write-Host "Continuing with governed access processing."

    }


    # ========================================================
    # Remove Governed HR Access
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Removing Governed HR Access"
    Write-Host "============================================"

    Write-Host ""
    Write-Host "Checking HR Operations Access Package assignment..."

    try {

        # Re-query the current delivered assignment
        $HrAccessPackage = Get-MgEntitlementManagementAccessPackage `
            -Filter "displayName eq 'HR Operations Access Package'" `
            -ErrorAction Stop

        if (-not $HrAccessPackage) {

            Write-Host "ERROR: HR Operations Access Package could not be found."
            continue

        }

        $HrAssignmentFilter = "accessPackage/id eq '$($HrAccessPackage.Id)' and state eq 'Delivered' and target/objectId eq '$($EntraUser.Id)'"

        $HrAccessPackageAssignment = Get-MgEntitlementManagementAssignment `
            -Filter $HrAssignmentFilter `
            -ExpandProperty target,accessPackage `
            -ErrorAction Stop

        if ($HrAccessPackageAssignment -is [array]) {

            $HrAccessPackageAssignment = $HrAccessPackageAssignment | Select-Object -First 1

        }

        if (-not $HrAccessPackageAssignment) {

            Write-Host "No delivered HR Operations Access Package assignment was found."
            Write-Host "No HR entitlement removal is required."

        }
        else {

            Write-Host "Delivered HR Operations Access Package assignment found."
            Write-Host "Submitting governed access removal request..."

            $RemovalRequest = @{
                RequestType = "AdminRemove"
                Assignment  = @{
                    Id = $HrAccessPackageAssignment.Id
                }
            }

            New-MgEntitlementManagementAssignmentRequest `
                -BodyParameter $RemovalRequest `
                -ErrorAction Stop | Out-Null

            Write-Host "HR Operations Access Package removal request submitted successfully."

        }

    }
    catch {

        Write-Host "ERROR: Unable to remove HR Operations Access Package."
        Write-Host $_.Exception.Message
        Write-Host "Mover process stopped."
        continue

    }

    # ========================================================
    # Verify Governed HR Access Removal
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Verifying HR Access Removal"
    Write-Host "============================================"

    Write-Host ""
    Write-Host "Waiting for Entitlement Management to process deprovisioning..."

    Start-Sleep -Seconds 10


    # ========================================================
    # Verify HR Access Package Assignment
    # ========================================================

    Write-Host ""
    Write-Host "Checking HR Operations Access Package..."

    try {

        $HrAssignmentAfterRemoval = Get-MgEntitlementManagementAssignment `
            -Filter $HrAssignmentFilter `
            -ExpandProperty target,accessPackage `
            -ErrorAction Stop

        if (-not $HrAssignmentAfterRemoval) {

            Write-Host "PASS: No delivered HR Operations Access Package assignment remains."
            $HrAccessPackageRemoved = $true

        }
        else {

            Write-Host "WARNING: HR Operations Access Package is still delivered."
            Write-Host "Entitlement deprovisioning may still be processing."
            $HrAccessPackageRemoved = $false

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify HR Operations Access Package removal."
        Write-Host $_.Exception.Message
        $HrAccessPackageRemoved = $false

    }


    # ========================================================
    # Verify HR Team Membership Removal
    # ========================================================

    Write-Host ""
    Write-Host "Checking HR Team membership..."

    try {

        $HrTeamGroup = Get-MgGroup `
            -Filter "displayName eq 'HR Team'" `
            -ErrorAction Stop

        if (-not $HrTeamGroup) {

            Write-Host "ERROR: HR Team security group could not be found."
            $HrTeamRemoved = $false

        }
        else {

            $HrTeamMembers = Get-MgGroupMember `
                -GroupId $HrTeamGroup.Id `
                -All `
                -ErrorAction Stop

            $IsHrTeamMember = $HrTeamMembers.Id -contains $EntraUser.Id

            if (-not $IsHrTeamMember) {

                Write-Host "PASS: $($EntraUser.DisplayName) is no longer a member of HR Team."
                $HrTeamRemoved = $true

            }
            else {

                Write-Host "WARNING: $($EntraUser.DisplayName) is still a member of HR Team."
                Write-Host "Group deprovisioning may still be processing."
                $HrTeamRemoved = $false

            }

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify HR Team membership."
        Write-Host $_.Exception.Message
        $HrTeamRemoved = $false

    }


    # ========================================================
    # HR Deprovisioning Summary
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "HR DEPROVISIONING SUMMARY"
    Write-Host "============================================"

    if ($HrAccessPackageRemoved) {
        Write-Host "[PASS] HR Operations Access Package - Removed"
    }
    else {
        Write-Host "[PENDING] HR Operations Access Package - Verify Again"
    }

    if ($HrTeamRemoved) {
        Write-Host "[PASS] HR Team - Removed through Entitlement Management"
    }
    else {
        Write-Host "[PENDING] HR Team - Verify Again"
    }



    # ========================================================
    # Enforce Successful HR Deprovisioning
    # ========================================================

    if (-not $HrAccessPackageRemoved -or -not $HrTeamRemoved) {

        Write-Host ""
        Write-Host "ERROR: HR access deprovisioning has not been fully verified."
        Write-Host "Finance access will not be provisioned until old HR access is removed."
        Write-Host "Mover process stopped to prevent access overlap."

        continue

    }

    Write-Host ""
    Write-Host "PASS: Previous HR access has been fully removed."
    Write-Host "Mover workflow can proceed with Finance provisioning."





    # ========================================================
    # Assign Governed Finance Access
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Assigning Governed Finance Access"
    Write-Host "============================================"

    Write-Host ""
    Write-Host "Checking Finance Operations Access Package..."

    try {

        $FinanceAccessPackage = Get-MgEntitlementManagementAccessPackage `
            -Filter "displayName eq 'Finance Operations Access Package'" `
            -ErrorAction Stop

        if (-not $FinanceAccessPackage) {

            Write-Host "ERROR: Finance Operations Access Package could not be found."
            continue

        }

        Write-Host "Finance Operations Access Package located."


        # Check whether Bryce already has the Finance package
        $FinanceAssignmentFilter = "accessPackage/id eq '$($FinanceAccessPackage.Id)' and state eq 'Delivered' and target/objectId eq '$($EntraUser.Id)'"

        $FinanceAccessPackageAssignment = Get-MgEntitlementManagementAssignment `
            -Filter $FinanceAssignmentFilter `
            -ExpandProperty target,accessPackage `
            -ErrorAction Stop


        if ($FinanceAccessPackageAssignment) {

            Write-Host "PASS: $($EntraUser.DisplayName) already has the Finance Operations Access Package."
            Write-Host "No new Finance assignment is required."

        }
        else {

            Write-Host "$($EntraUser.DisplayName) does not currently have the Finance Operations Access Package."
            Write-Host "Submitting governed Finance access assignment request..."


            # Retrieve Finance Access Package and its assignment policies
            $FinancePackageWithPolicies = Get-MgEntitlementManagementAccessPackage `
               -AccessPackageId $FinanceAccessPackage.Id `
               -ExpandProperty "assignmentPolicies" `
               -ErrorAction Stop

           # Locate the required Finance assignment policy
           $FinanceAssignmentPolicy = $FinancePackageWithPolicies.AssignmentPolicies |
               Where-Object { $_.DisplayName -eq "Initial Policy" } |
               Select-Object -First 1

            if (-not $FinanceAssignmentPolicy) {

                Write-Host "ERROR: Initial Policy could not be found for the Finance Operations Access Package."
                continue

            }

            Write-Host "Finance assignment policy located: $($FinanceAssignmentPolicy.DisplayName)"

            $FinanceRequest = @{
                RequestType = "AdminAdd"
                Assignment  = @{
                    TargetId        = $EntraUser.Id
                    AssignmentPolicyId = $FinanceAssignmentPolicy.Id
                    AccessPackageId = $FinanceAccessPackage.Id
                }
            }

            New-MgEntitlementManagementAssignmentRequest `
                -BodyParameter $FinanceRequest `
                -ErrorAction Stop | Out-Null

            Write-Host "Finance Operations Access Package assignment request submitted successfully."

        }

    }
    catch {

        Write-Host "ERROR: Unable to assign Finance Operations Access Package."
        Write-Host $_.Exception.Message
        Write-Host "Mover process stopped."
        continue

    }


    # ========================================================
    # Verify Governed Finance Access Provisioning
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Verifying Finance Access Provisioning"
    Write-Host "============================================"

    Write-Host ""
    Write-Host "Waiting for Entitlement Management provisioning..."

    Start-Sleep -Seconds 10


    # ========================================================
    # Verify Finance Access Package Assignment
    # ========================================================

    Write-Host ""
    Write-Host "Checking Finance Operations Access Package..."

    try {

        $FinanceAssignmentAfterProvisioning = Get-MgEntitlementManagementAssignment `
            -Filter $FinanceAssignmentFilter `
            -ExpandProperty target,accessPackage `
            -ErrorAction Stop

        if ($FinanceAssignmentAfterProvisioning) {

            Write-Host "PASS: Finance Operations Access Package is delivered."
            $FinanceAccessPackageDelivered = $true

        }
        else {

            Write-Host "WARNING: Finance Operations Access Package is not yet delivered."
            Write-Host "Entitlement provisioning may still be processing."
            $FinanceAccessPackageDelivered = $false

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify Finance Operations Access Package."
        Write-Host $_.Exception.Message
        $FinanceAccessPackageDelivered = $false

    }


    # ========================================================
    # Verify Finance Team Membership
    # ========================================================

    Write-Host ""
    Write-Host "Checking Finance Team membership..."

    try {

        $FinanceTeamGroup = Get-MgGroup `
            -Filter "displayName eq 'Finance Team'" `
            -ErrorAction Stop

        if (-not $FinanceTeamGroup) {

            Write-Host "ERROR: Finance Team security group could not be found."
            $FinanceTeamProvisioned = $false

        }
        else {

            $FinanceTeamMembers = Get-MgGroupMember `
                -GroupId $FinanceTeamGroup.Id `
                -All `
                -ErrorAction Stop

            $IsFinanceTeamMember = $FinanceTeamMembers.Id -contains $EntraUser.Id

            if ($IsFinanceTeamMember) {

                Write-Host "PASS: $($EntraUser.DisplayName) is a member of Finance Team."
                $FinanceTeamProvisioned = $true

            }
            else {

                Write-Host "WARNING: $($EntraUser.DisplayName) is not yet a member of Finance Team."
                Write-Host "Group provisioning may still be processing."
                $FinanceTeamProvisioned = $false

            }

        }

    }
    catch {

        Write-Host "ERROR: Unable to verify Finance Team membership."
        Write-Host $_.Exception.Message
        $FinanceTeamProvisioned = $false

    }


    # ========================================================
    # Finance Provisioning Summary
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "FINANCE PROVISIONING SUMMARY"
    Write-Host "============================================"

    if ($FinanceAccessPackageDelivered) {
        Write-Host "[PASS] Finance Operations Access Package - Delivered"
    }
    else {
        Write-Host "[PENDING] Finance Operations Access Package - Verify Again"
    }

    if ($FinanceTeamProvisioned) {
        Write-Host "[PASS] Finance Team - Provisioned through Entitlement Management"
    }
    else {
        Write-Host "[PENDING] Finance Team - Verify Again"
    }


if (-not $FinanceAccessPackageDelivered -or -not $FinanceTeamProvisioned) {

    Write-Host ""
    Write-Host "ERROR: Finance access provisioning has not been fully verified."
    Write-Host "Final mover validation will not proceed until required Finance access is confirmed."

    continue

}

Write-Host ""
Write-Host "PASS: Required Finance access has been fully provisioned."
Write-Host "Mover workflow can proceed with final validation."

    # ========================================================
    # Final Mover Validation
    # ========================================================

    Write-Host ""
    Write-Host "============================================"
    Write-Host "FINAL MOVER VALIDATION"
    Write-Host "============================================"

    $FinalValidationPassed = $true


    # ========================================================
    # Refresh Final Employee Identity
    # ========================================================

    try {

        $FinalUser = Get-MgUser `
            -UserId $Employee.UserPrincipalName `
            -Property Id,DisplayName,UserPrincipalName,Department,JobTitle,AccountEnabled `
            -ErrorAction Stop

    }
    catch {

        Write-Host "ERROR: Unable to retrieve final employee identity state."
        Write-Host $_.Exception.Message
        continue

    }


    # ========================================================
    # Validate Department
    # ========================================================

    if ($FinalUser.Department -eq $Employee.NewDepartment) {

        Write-Host "[PASS] Department - $($FinalUser.Department)"

    }
    else {

        Write-Host "[FAIL] Department - $($FinalUser.Department)"
        $FinalValidationPassed = $false

    }


    # ========================================================
    # Validate Job Title
    # ========================================================

    if ($FinalUser.JobTitle -eq $Employee.NewJobTitle) {

        Write-Host "[PASS] Job Title - $($FinalUser.JobTitle)"

    }
    else {

        Write-Host "[FAIL] Job Title - $($FinalUser.JobTitle)"
        $FinalValidationPassed = $false

    }


    # ========================================================
    # Validate Baseline Access
    # ========================================================

    $FinalAllEmployeesMembers = Get-MgGroupMember `
        -GroupId $AllEmployeesGroup.Id `
        -All `
        -ErrorAction Stop

    $FinalAllEmployeesMembership =
        $FinalAllEmployeesMembers.Id -contains $FinalUser.Id

    if ($FinalAllEmployeesMembership) {

        Write-Host "[PASS] All Employees - Retained"

    }
    else {

        Write-Host "[FAIL] All Employees - Missing"
        $FinalValidationPassed = $false

    }


    # ========================================================
    # Validate HR Access Removed
    # ========================================================

    $FinalHrAssignment = Get-MgEntitlementManagementAssignment `
        -Filter $HrAssignmentFilter `
        -ErrorAction Stop

    if (-not $FinalHrAssignment) {

        Write-Host "[PASS] HR Operations Access Package - Removed"

    }
    else {

        Write-Host "[FAIL] HR Operations Access Package - Still Present"
        $FinalValidationPassed = $false

    }


    $FinalHrTeamMembers = Get-MgGroupMember `
        -GroupId $HrTeamGroup.Id `
        -All `
        -ErrorAction Stop

    $FinalHrTeamMembership =
        $FinalHrTeamMembers.Id -contains $FinalUser.Id

    if (-not $FinalHrTeamMembership) {

        Write-Host "[PASS] HR Team - Removed"

    }
    else {

        Write-Host "[FAIL] HR Team - Still Present"
        $FinalValidationPassed = $false

    }


    # ========================================================
    # Validate Finance Access Provisioned
    # ========================================================

    $FinalFinanceAssignment = Get-MgEntitlementManagementAssignment `
        -Filter $FinanceAssignmentFilter `
        -ErrorAction Stop

    if ($FinalFinanceAssignment) {

        Write-Host "[PASS] Finance Operations Access Package - Delivered"

    }
    else {

        Write-Host "[FAIL] Finance Operations Access Package - Missing"
        $FinalValidationPassed = $false

    }


    $FinalFinanceTeamMembers = Get-MgGroupMember `
        -GroupId $FinanceTeamGroup.Id `
        -All `
        -ErrorAction Stop

    $FinalFinanceTeamMembership =
        $FinalFinanceTeamMembers.Id -contains $FinalUser.Id

    if ($FinalFinanceTeamMembership) {

        Write-Host "[PASS] Finance Team - Provisioned"

    }
    else {

        Write-Host "[FAIL] Finance Team - Missing"
        $FinalValidationPassed = $false

    }


    # ========================================================
    # Final Mover Result
    # ========================================================

    Write-Host ""
    Write-Host "============================================"

    if ($FinalValidationPassed) {

        Write-Host "MOVER STATUS: SUCCESS"
        Write-Host "$($FinalUser.DisplayName)'s $($Employee.CurrentDepartment) to $($Employee.NewDepartment) transfer has been successfully validated."

    }
    else {

        Write-Host "MOVER STATUS: FAILED"
        Write-Host "One or more final-state controls failed validation."

    }

    Write-Host "============================================"


    # ========================================================
    # Generate Post-Move Report
    # ========================================================

    Write-Host ""
    Write-Host "Generating post-move report..."

    $PostMoveReportPath = Join-Path $PSScriptRoot "..\Reports\Mover-PostChange-Report.csv"

    $PostMoveReport = [PSCustomObject]@{

        Timestamp                      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DisplayName                    = $FinalUser.DisplayName
        UserPrincipalName              = $FinalUser.UserPrincipalName
        Department                     = $FinalUser.Department
        JobTitle                       = $FinalUser.JobTitle
        AccountEnabled                 = $FinalUser.AccountEnabled
        AllEmployeesAccess             = $FinalAllEmployeesMembership
        HrOperationsAccessPackage      = [bool]$FinalHrAssignment
        HrTeamMembership               = $FinalHrTeamMembership
        FinanceOperationsAccessPackage = [bool]$FinalFinanceAssignment
        FinanceTeamMembership          = $FinalFinanceTeamMembership
        MoverStatus                    = if ($FinalValidationPassed) { "SUCCESS" } else { "FAILED" }

    }

    $PostMoveReport |
        Export-Csv `
            -Path $PostMoveReportPath `
            -NoTypeInformation `
            -Force

    Write-Host "Post-move report generated successfully."
    Write-Host "Report: $PostMoveReportPath"


    # ========================================================
    # Generate Mover Audit Report
    # ========================================================

    Write-Host ""
    Write-Host "Generating mover audit report..."

    $AuditReportPath = Join-Path $PSScriptRoot "..\Reports\Mover-Audit-Report.csv"

    $AuditReport = @(

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "Department"
            Previous  = $Employee.CurrentDepartment
            Current   = $FinalUser.Department
            Action    = "Updated"
            Result    = if ($FinalUser.Department -eq $Employee.NewDepartment) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "Job Title"
            Previous  = $Employee.CurrentJobTitle
            Current   = $FinalUser.JobTitle
            Action    = "Updated"
            Result    = if ($FinalUser.JobTitle -eq $Employee.NewJobTitle) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "All Employees"
            Previous  = "Present"
            Current   = if ($FinalAllEmployeesMembership) { "Present" } else { "Missing" }
            Action    = "Retained"
            Result    = if ($FinalAllEmployeesMembership) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "HR Operations Access Package"
            Previous  = "Delivered"
            Current   = if ($FinalHrAssignment) { "Delivered" } else { "Removed" }
            Action    = "Deprovisioned"
            Result    = if (-not $FinalHrAssignment) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "HR Team"
            Previous  = "Present"
            Current   = if ($FinalHrTeamMembership) { "Present" } else { "Removed" }
            Action    = "Deprovisioned"
            Result    = if (-not $FinalHrTeamMembership) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "Finance Operations Access Package"
            Previous  = "Not Assigned"
            Current   = if ($FinalFinanceAssignment) { "Delivered" } else { "Missing" }
            Action    = "Provisioned"
            Result    = if ($FinalFinanceAssignment) { "PASS" } else { "FAIL" }
        }

        [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Employee  = $FinalUser.DisplayName
            Control   = "Finance Team"
            Previous  = "Not Present"
            Current   = if ($FinalFinanceTeamMembership) { "Present" } else { "Missing" }
            Action    = "Provisioned"
            Result    = if ($FinalFinanceTeamMembership) { "PASS" } else { "FAIL" }
        }

    )

    $AuditReport |
        Export-Csv `
            -Path $AuditReportPath `
            -NoTypeInformation `
            -Force

    Write-Host "Mover audit report generated successfully."
    Write-Host "Report: $AuditReportPath"

}