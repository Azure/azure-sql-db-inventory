# Get the list of databases
databases=$(az resource list --resource-type "Microsoft.Sql/servers/databases" --query "[].{Name:name, ResourceGroup:resourceGroup}" --output json)

# Extract unique server-resourceGroup pairs
unique_servers=$(echo "$databases" | jq -r '.[] | "\(.Name | split("/")[0]) \(.ResourceGroup)"' | sort -u)

# Iterate through each unique server
echo "$unique_servers" | while read -r server resource_group; do
    echo "Fetching details for Resource Group: $resource_group, Server: $server"
    az sql db list --resource-group "$resource_group" --server "$server" --query "[].{Name:name, Size:currentServiceObjectiveName, Status:status, ZoneRedundant:zoneRedundant}" --output table
done
