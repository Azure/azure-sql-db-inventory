# Output CSV file path
$outputFile = "sql_databases.csv"

# Write CSV header
"ResourceGroup,Server,DatabaseName,Size,Status,ZoneRedundant" | Out-File -FilePath $outputFile -Encoding utf8

# Get list of SQL databases
$databases = az resource list --resource-type "Microsoft.Sql/servers/databases" --query "[].{Id:id, ResourceGroup:resourceGroup}" --output json | ConvertFrom-Json

# Extract unique server-resourceGroup pairs
$uniquePairs = $databases | ForEach-Object {
    $serverName = ($_.Id -split "/")[8]
    "$($serverName) $($_.ResourceGroup)"
} | Sort-Object -Unique

# Iterate through each unique pair
foreach ($pair in $uniquePairs) {
    $parts = $pair -split " "
    $server = $parts[0]
    $resourceGroup = $parts[1]

    Write-Host "Fetching details for Resource Group: $resourceGroup, Server: $server"

    $dbs = az sql db list --resource-group $resourceGroup --server $server --query "[].{Name:name, Size:currentServiceObjectiveName, Status:status, ZoneRedundant:zoneRedundant}" --output json | ConvertFrom-Json

    foreach ($db in $dbs) {
        "$resourceGroup,$server,$($db.Name),$($db.Size),$($db.Status),$($db.ZoneRedundant)" | Out-File -FilePath $outputFile -Append -Encoding utf8
    }
}

Write-Host "`n✅ Output saved to $outputFile"
