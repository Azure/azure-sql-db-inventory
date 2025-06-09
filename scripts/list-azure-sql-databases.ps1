# Get all subscriptions
$subscriptions = az account list --query "[].{Id:id, Name:name}" --output json | ConvertFrom-Json | Sort-Object Name

# Total subscription count
$subscriptionCount = $subscriptions.Count
Write-Host "Total subscriptions found: $subscriptionCount`n" -ForegroundColor Yellow

# Output CSV file path
$outputFile = "sql_databases.csv"

# Get current collection date
$collectionDate = (Get-Date).ToString("yyyy-MM-dd")

# Write CSV header (with CollectionDate)
"SubscriptionId,SubscriptionName,ResourceGroup,ServerOrInstance,DatabaseName,Status,RedundancyType,Type,StorageSizeGB,FailoverGroupName,Compute,ComputeDetails,CollectionDate" | Out-File -FilePath $outputFile -Encoding utf8

# Counter for total databases
$totalDatabases = 0

# Loop through each subscription
foreach ($sub in $subscriptions) {
    $subscriptionId = $sub.Id
    $subscriptionName = $sub.Name

    Write-Host "Switching to subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Cyan
    az account set --subscription $subscriptionId

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

        Write-Host "Querying SQL DBs for RG: $resourceGroup, Server: $server"

        $dbs = az sql db list --resource-group $resourceGroup --server $server --query "[].{Name:name, Status:status}" --output json | ConvertFrom-Json

        foreach ($db in $dbs) {
            $dbDetails = az sql db show --name $($db.Name) --resource-group $resourceGroup --server $server --output json | ConvertFrom-Json
            $storageSizeGB = [math]::Round($dbDetails.maxSizeBytes / 1073741824, 2)

            $redundancyType = "None"
            if ($dbDetails.zoneRedundant -eq $true) { $redundancyType = "Zone Redundant" }

            if ($dbDetails.requestedBackupStorageRedundancy) {
                switch ($dbDetails.requestedBackupStorageRedundancy) {
                    "Geo" { if ($redundancyType -eq "Zone Redundant") { $redundancyType = "Zone and Geo Redundant" } else { $redundancyType = "Geo Redundant" } }
                    "Zone" { if ($redundancyType -ne "Zone Redundant") { $redundancyType = "Zone Redundant Storage" } }
                    "Local" { if ($redundancyType -eq "None") { $redundancyType = "Local Redundant" } }
                    "GeoZone" { $redundancyType = "Geo-Zone Redundant" }
                }
            }

            $compute = ""
            $computeDetails = ""
            if ($dbDetails.sku.PSObject.Properties['name']) { $compute = $dbDetails.sku.name }
            elseif ($dbDetails.sku.PSObject.Properties['tier']) { $compute = $dbDetails.sku.tier }

            if ($dbDetails.sku.PSObject.Properties['capacity']) {
                if ($dbDetails.sku.tier -like '*vCore*' -or $dbDetails.sku.family -or $dbDetails.sku.name -match 'Gen') {
                    $computeDetails = "$($dbDetails.sku.capacity) vCores"
                } else {
                    $computeDetails = "$($dbDetails.sku.capacity) DTUs"
                }
            } elseif ($dbDetails.PSObject.Properties['currentServiceObjectiveName']) {
                $computeDetails = "$($dbDetails.currentServiceObjectiveName)"
            }

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

            if ($redundancyType -eq "None" -and ($db.Size -like "*Premium*" -or $db.Size -like "*Business*" -or $db.Size -like "*Critical*")) {
                $redundancyType = "Local Redundancy (Premium/Business Critical)"
            }

            # Write row
            "$subscriptionId,$subscriptionName,$resourceGroup,$server,$($db.Name),$($db.Status),$redundancyType,SQLDatabase,$storageSizeGB,$failoverGroupName,$compute,$computeDetails,$collectionDate" | Out-File -FilePath $outputFile -Append -Encoding utf8
            $totalDatabases++
        }
    }

    # --- Managed Instances ---
    $instances = az sql mi list --query "[].{Name:name, ResourceGroup:resourceGroup}" --output json | ConvertFrom-Json

    foreach ($instance in $instances) {
        $miName = $instance.Name
        $resourceGroup = $instance.ResourceGroup

        Write-Host "Querying Managed DBs for RG: $resourceGroup, Instance: $miName"

        $miDetails = az sql mi show --name $miName --resource-group $resourceGroup --output json | ConvertFrom-Json
        $storageSizeGB = [math]::Round($miDetails.storageSizeInGB, 2)

        $redundancyType = "None"
        if ($miDetails.zoneRedundant -eq $true) { $redundancyType = "Zone Redundant" }
        if ($miDetails.availabilityZone) { $redundancyType = "Availability Zone: $($miDetails.availabilityZone)" }

        if ($miDetails.requestedBackupStorageRedundancy) {
            switch ($miDetails.requestedBackupStorageRedundancy) {
                "Geo" { if ($redundancyType -eq "Zone Redundant") { $redundancyType = "Zone and Geo Redundant" } else { $redundancyType = "Geo Redundant" } }
                "Zone" { if ($redundancyType -ne "Zone Redundant") { $redundancyType = "Zone Redundant Storage" } }
                "Local" { if ($redundancyType -eq "None") { $redundancyType = "Local Redundant" } }
                "GeoZone" { $redundancyType = "Geo-Zone Redundant" }
            }
        }

        if ($miDetails.haMode) {
            $redundancyType = "$redundancyType with $($miDetails.haMode) HA"
        }

        if ($redundancyType -eq "None" -and $miDetails.sku.tier -eq "BusinessCritical") {
            $redundancyType = "Local Redundancy (Business Critical)"
        }

        $miCompute = ""
        $miComputeDetails = ""
        if ($miDetails.sku.PSObject.Properties['name']) { $miCompute = $miDetails.sku.name }
        elseif ($miDetails.sku.PSObject.Properties['tier']) { $miCompute = $miDetails.sku.tier }
        if ($miDetails.sku.PSObject.Properties['capacity']) {
            $miComputeDetails = "$($miDetails.sku.capacity) vCores"
        }

        $failoverGroupName = "Pendiente de verificar"
        $managedDbs = az sql midb list --managed-instance $miName --resource-group $resourceGroup --query "[].{Name:name, Status:status}" --output json | ConvertFrom-Json

        foreach ($db in $managedDbs) {
            $dbDetails = az sql midb show --name $($db.Name) --managed-instance $miName --resource-group $resourceGroup --output json | ConvertFrom-Json
            $dbStorageSizeGB = $storageSizeGB
            if ($dbDetails.PSObject.Properties['maxSizeBytes']) {
                $dbStorageSizeGB = [math]::Round($dbDetails.maxSizeBytes / 1073741824, 2)
            }

            "$subscriptionId,$subscriptionName,$resourceGroup,$miName,$($db.Name),$($db.Status),$redundancyType,ManagedInstance,$dbStorageSizeGB,$failoverGroupName,$miCompute,$miComputeDetails,$collectionDate" | Out-File -FilePath $outputFile -Append -Encoding utf8
            $totalDatabases++
        }
    }
}

# Final output message
Write-Host "Scan completed. $totalDatabases databases written to: $outputFile`n" -ForegroundColor Green
