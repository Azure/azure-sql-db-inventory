# Output CSV file path
$outputFile = "sql_databases.csv"

# Write CSV header
"ResourceGroup,ServerOrInstance,DatabaseName,Status,RedundancyType,Type,StorageSizeGB,FailoverGroupName,Compute,ComputeDetails" | Out-File -FilePath $outputFile -Encoding utf8

# --- SQL Databases (PaaS) ---
$databases = az resource list --resource-type "Microsoft.Sql/servers/databases" --query "[].{Id:id, ResourceGroup:resourceGroup}" --output json | ConvertFrom-Json

$uniquePairs = $databases | ForEach-Object {
$serverName = ($_.Id -split "/")[8]
"$($serverName) $($_.ResourceGroup)"
} | Sort-Object -Unique

foreach ($pair in $uniquePairs) {
    $parts = $pair -split " "
    $server = $parts[0]
    $resourceGroup = $parts[1]

    Write-Host "Fetching SQL DBs for Resource Group: $resourceGroup, Server: $server"

    $dbs = az sql db list --resource-group $resourceGroup --server $server --query "[].{Name:name, Status:status}" --output json | ConvertFrom-Json

    foreach ($db in $dbs) {
        # Get detailed info for each database, focusing directly on properties we need
        $dbDetails = az sql db show --name $($db.Name) --resource-group $resourceGroup --server $server --output json | ConvertFrom-Json
          # Extract storage size in GB (convert bytes to GB)
        $storageSizeGB = [math]::Round($dbDetails.maxSizeBytes / 1073741824, 2) # 1073741824 = 1GB in bytes
        
        # Determine redundancy type based on the available properties
        $redundancyType = "None"
        
        # First check zone redundancy (most specific)
        if ($dbDetails.zoneRedundant -eq $true) {
            $redundancyType = "Zone Redundant"
        }
        
        # Check backup storage redundancy which can indicate geo redundancy
        if ($dbDetails.requestedBackupStorageRedundancy) {
            switch ($dbDetails.requestedBackupStorageRedundancy) {
                "Geo" { 
                    if ($redundancyType -eq "Zone Redundant") {
                        $redundancyType = "Zone and Geo Redundant"
                    } else {
                        $redundancyType = "Geo Redundant" 
                    }
                }
                "Zone" { 
                    if ($redundancyType -ne "Zone Redundant") {
                        $redundancyType = "Zone Redundant Storage" 
                    }
                }
                "Local" { 
                    if ($redundancyType -eq "None") {
                        $redundancyType = "Local Redundant" 
                    }
                }
                "GeoZone" { $redundancyType = "Geo-Zone Redundant" }
            }
        }
        
        # Compute info for SQL Database
        $compute = $null
        $computeDetails = ""
        if ($dbDetails.sku.PSObject.Properties['name']) { $compute = $dbDetails.sku.name }
        elseif ($dbDetails.sku.PSObject.Properties['tier']) { $compute = $dbDetails.sku.tier }
        else { $compute = $db.Size }
        # ComputeDetails: DTUs or vCores
        if ($dbDetails.sku.PSObject.Properties['capacity']) {
            if ($dbDetails.sku.tier -like '*vCore*' -or $dbDetails.sku.family -or $dbDetails.sku.name -match 'Gen') {
                $computeDetails = "$($dbDetails.sku.capacity) vCores"
            } else {
                $computeDetails = "$($dbDetails.sku.capacity) DTUs"
            }
        } elseif ($dbDetails.PSObject.Properties['currentServiceObjectiveName'] -and $dbDetails.currentServiceObjectiveName -match '\d+') {
            $computeDetails = "$($dbDetails.currentServiceObjectiveName)"
        }
        # Improved failover group detection
        # Find failover group name(s) for SQL Database
        $failoverGroupName = ""
        try {
            $failoverGroups = az sql failover-group list --resource-group $resourceGroup --server $server --output json | ConvertFrom-Json
            $fgNames = @()
            foreach ($fg in $failoverGroups) {
                if ($fg.databases -contains $dbDetails.id) {
                    $fgNames += $fg.name
                    if ($redundancyType -eq "Zone Redundant") {
                        $redundancyType = "Zone Redundant with Geo Failover"
                    } else {
                        $redundancyType = "Geo Redundant (Failover Group)"
                    }
                }
            }
            if ($fgNames.Count -gt 0) { $failoverGroupName = $fgNames -join ";" }
        } catch {}
        # For premium and business critical tiers, they have local redundancy by default
        if ($redundancyType -eq "None" -and ($db.Size -like "*Premium*" -or $db.Size -like "*Business*" -or $db.Size -like "*Critical*")) {
            $redundancyType = "Local Redundancy (Premium/Business Critical)"
        }

        "$resourceGroup,$server,$($db.Name),$($db.Status),$redundancyType,SQLDatabase,$storageSizeGB,$failoverGroupName,$compute,$computeDetails" | Out-File -FilePath $outputFile -Append -Encoding utf8
    }
}

# --- Managed Instances ---
$instances = az sql mi list --query "[].{Name:name, ResourceGroup:resourceGroup}" --output json | ConvertFrom-Json

$subscriptionId = az account show --query id -o tsv
$apiVersion = "2021-11-01"

foreach ($instance in $instances) {
    $miName = $instance.Name
    $resourceGroup = $instance.ResourceGroup

    Write-Host "Fetching Managed DBs for Resource Group: $resourceGroup, Instance: $miName"

    # Get detailed instance info
    $miDetails = az sql mi show --name $miName --resource-group $resourceGroup --output json | ConvertFrom-Json

    # Extract storage size in GB (already in GB units)
    $storageSizeGB = [math]::Round($miDetails.storageSizeInGB, 2)

    # Determine redundancy type for managed instance
    $redundancyType = "None"

    # Check zone redundancy (most specific property)
    if ($miDetails.zoneRedundant -eq $true) {
        $redundancyType = "Zone Redundant"
    }

    # Check availability zones
    if ($miDetails.availabilityZone) {
        $redundancyType = "Availability Zone: $($miDetails.availabilityZone)"
    }

    # Check backup storage redundancy which can indicate geo redundancy
    if ($miDetails.requestedBackupStorageRedundancy) {
        switch ($miDetails.requestedBackupStorageRedundancy) {
            "Geo" { 
                if ($redundancyType -eq "Zone Redundant") {
                    $redundancyType = "Zone and Geo Redundant"
                } else {
                    $redundancyType = "Geo Redundant" 
                }
            }
            "Zone" { 
                if ($redundancyType -ne "Zone Redundant") {
                    $redundancyType = "Zone Redundant Storage" 
                }
            }
            "Local" { 
                if ($redundancyType -eq "None") {
                    $redundancyType = "Local Redundant" 
                }
            }
            "GeoZone" { $redundancyType = "Geo-Zone Redundant" }
        }
    }

    # Check high availability configuration
    if ($miDetails.haMode) {
        if ($redundancyType -ne "None") {
            $redundancyType = "$redundancyType with $($miDetails.haMode) HA"
        } else {
            $redundancyType = "$($miDetails.haMode) HA"
        }
    }

    # Check if it's Business Critical tier (which has local redundancy by default)
    if ($redundancyType -eq "None" -and $miDetails.sku.tier -eq "BusinessCritical") {
        $redundancyType = "Local Redundancy (Business Critical)"
    }
    # Compute info for Managed Instance
    $miCompute = $null
    $miComputeDetails = ""
    if ($miDetails.sku.PSObject.Properties['name']) { $miCompute = $miDetails.sku.name }
    elseif ($miDetails.sku.PSObject.Properties['tier']) { $miCompute = $miDetails.sku.tier }
    if ($miDetails.sku.PSObject.Properties['capacity']) {
        $miComputeDetails = "$($miDetails.sku.capacity) vCores"
    }
    # Set FailoverGroupName to 'Pendiente de verificar' for all managed instance databases
    $failoverGroupName = "Pendiente de verificar"
    $managedDbs = az sql midb list --managed-instance $miName --resource-group $resourceGroup --query "[].{Name:name, Status:status}" --output json | ConvertFrom-Json

    foreach ($db in $managedDbs) {
        # Get individual managed DB details to check if there's any specific storage size (fallback to instance size if not available)
        $dbDetails = az sql midb show --name $($db.Name) --managed-instance $miName --resource-group $resourceGroup --output json | ConvertFrom-Json
        
        # Use DB-specific storage size if available, otherwise use the instance level storage size
        $dbStorageSizeGB = $storageSizeGB
        if ($dbDetails.PSObject.Properties['maxSizeBytes']) {
            $dbStorageSizeGB = [math]::Round($dbDetails.maxSizeBytes / 1073741824, 2) # 1073741824 = 1GB in bytes
        }
        
        "$resourceGroup,$miName,$($db.Name),$($db.Status),$redundancyType,ManagedInstance,$dbStorageSizeGB,$failoverGroupName,$miCompute,$miComputeDetails" | Out-File -FilePath $outputFile -Append -Encoding utf8
    }
}

Write-Host "`n✅ Output saved to $outputFile"
