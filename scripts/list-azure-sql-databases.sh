#!/bin/bash

# Output file
output_file="sql_databases.csv"

# Write CSV header
echo "SubscriptionName,ResourceGroup,ServerOrInstance,DatabaseName,Status,RedundancyType,Type,StorageSizeGB,FailoverGroupName,Compute,ComputeDetails" > "$output_file"

# Get and sort all subscriptions
subscriptions=$(az account list --query "[].{id:id, name:name}" -o json | jq -c '.[]' | sort -t'"' -k4)

# Count subscriptions
count=$(echo "$subscriptions" | wc -l)
echo "Total subscriptions found: $count"

# Loop over subscriptions
echo "$subscriptions" | while read -r sub; do
    sub_id=$(echo "$sub" | jq -r '.id')
    sub_name=$(echo "$sub" | jq -r '.name')

    echo "Processing subscription: $sub_name"

    az account set --subscription "$sub_id"

    # --- SQL Databases ---
    dbs=$(az resource list --resource-type "Microsoft.Sql/servers/databases" -o json | jq -c '.[]')

    # Extract unique pairs (server, resource group)
    pairs=$(echo "$dbs" | jq -r '[.id, .resourceGroup] | "\(.[0] | split("/") | .[8]) \(.[1])"' | sort -u)

    echo "$pairs" | while read -r line; do
        server=$(echo "$line" | awk '{print $1}')
        rg=$(echo "$line" | awk '{print $2}')

        echo "📡 Getting databases from server: $server, RG: $rg"

        az sql db list --resource-group "$rg" --server "$server" -o json | jq -c '.[]' | while read -r db; do
            db_name=$(echo "$db" | jq -r '.name')
            status=$(echo "$db" | jq -r '.status')

            db_info=$(az sql db show --name "$db_name" --resource-group "$rg" --server "$server" -o json)

            max_size=$(echo "$db_info" | jq -r '.maxSizeBytes // 0')
            size_gb=$(awk "BEGIN { printf \"%.2f\", $max_size / (1024*1024*1024) }")

            zone=$(echo "$db_info" | jq -r '.zoneRedundant // false')
            redundancy="None"
            if [[ "$zone" == "true" ]]; then
                redundancy="Zone Redundant"
            fi

            backup_redundancy=$(echo "$db_info" | jq -r '.requestedBackupStorageRedundancy // empty')
            case "$backup_redundancy" in
                Geo)
                    [[ "$redundancy" == "Zone Redundant" ]] && redundancy="Zone and Geo Redundant" || redundancy="Geo Redundant"
                    ;;
                Zone)
                    [[ "$redundancy" != "Zone Redundant" ]] && redundancy="Zone Redundant Storage"
                    ;;
                Local)
                    [[ "$redundancy" == "None" ]] && redundancy="Local Redundant"
                    ;;
                GeoZone)
                    redundancy="Geo-Zone Redundant"
                    ;;
            esac

            # Compute info
            sku_name=$(echo "$db_info" | jq -r '.sku.name // empty')
            sku_tier=$(echo "$db_info" | jq -r '.sku.tier // empty')
            sku_capacity=$(echo "$db_info" | jq -r '.sku.capacity // empty')
            compute="${sku_name:-$sku_tier}"
            compute_details=""
            if [[ "$sku_capacity" != "" ]]; then
                if [[ "$sku_tier" == *"vCore"* || "$sku_name" =~ "Gen" ]]; then
                    compute_details="$sku_capacity vCores"
                else
                    compute_details="$sku_capacity DTUs"
                fi
            fi

            # Failover group name
            failover_group=""
            fg_data=$(az sql failover-group list --resource-group "$rg" --server "$server" -o json)
            if [[ "$fg_data" != "[]" ]]; then
                failover_group=$(echo "$fg_data" | jq -r --arg id "$db_name" '[.[] | select(.databases[] | contains($id)) | .name] | join(";")')
                [[ "$failover_group" != "" ]] && redundancy="Geo Redundant (Failover Group)"
            fi

            echo "$sub_name,$rg,$server,$db_name,$status,$redundancy,SQLDatabase,$size_gb,$failover_group,$compute,$compute_details" >> "$output_file"
        done
    done

    # --- Managed Instances ---
    az sql mi list -o json | jq -c '.[]' | while read -r mi; do
        mi_name=$(echo "$mi" | jq -r '.name')
        rg=$(echo "$mi" | jq -r '.resourceGroup')

        echo "Getting managed DBs from MI: $mi_name, RG: $rg"

        mi_info=$(az sql mi show --name "$mi_name" --resource-group "$rg" -o json)
        storage_size=$(echo "$mi_info" | jq -r '.storageSizeInGB // 0')
        ha_mode=$(echo "$mi_info" | jq -r '.haMode // empty')
        redundancy="None"

        zone=$(echo "$mi_info" | jq -r '.zoneRedundant // false')
        [[ "$zone" == "true" ]] && redundancy="Zone Redundant"

        zone_avail=$(echo "$mi_info" | jq -r '.availabilityZone // empty')
        [[ "$zone_avail" != "" ]] && redundancy="Availability Zone: $zone_avail"

        backup_redundancy=$(echo "$mi_info" | jq -r '.requestedBackupStorageRedundancy // empty')
        case "$backup_redundancy" in
            Geo)
                [[ "$redundancy" == "Zone Redundant" ]] && redundancy="Zone and Geo Redundant" || redundancy="Geo Redundant"
                ;;
            Zone)
                [[ "$redundancy" != "Zone Redundant" ]] && redundancy="Zone Redundant Storage"
                ;;
            Local)
                [[ "$redundancy" == "None" ]] && redundancy="Local Redundant"
                ;;
            GeoZone)
                redundancy="Geo-Zone Redundant"
                ;;
        esac

        [[ "$ha_mode" != "" ]] && redundancy="$redundancy with $ha_mode HA"

        sku_name=$(echo "$mi_info" | jq -r '.sku.name // empty')
        sku_tier=$(echo "$mi_info" | jq -r '.sku.tier // empty')
        sku_capacity=$(echo "$mi_info" | jq -r '.sku.capacity // empty')
        compute="${sku_name:-$sku_tier}"
        compute_details=""
        [[ "$sku_capacity" != "" ]] && compute_details="$sku_capacity vCores"

        az sql midb list --managed-instance "$mi_name" --resource-group "$rg" -o json | jq -c '.[]' | while read -r db; do
            db_name=$(echo "$db" | jq -r '.name')
            status=$(echo "$db" | jq -r '.status')
            db_info=$(az sql midb show --name "$db_name" --managed-instance "$mi_name" --resource-group "$rg" -o json)
            max_bytes=$(echo "$db_info" | jq -r '.maxSizeBytes // empty')
            if [[ "$max_bytes" != "" ]]; then
                size_gb=$(awk "BEGIN { printf \"%.2f\", $max_bytes / (1024*1024*1024) }")
            else
                size_gb=$storage_size
            fi

            echo "$sub_name,$rg,$mi_name,$db_name,$status,$redundancy,ManagedInstance,$size_gb,Pendiente de verificar,$compute,$compute_details" >> "$output_file"
        done
    done

done

echo -e "Output saved to $output_file"
