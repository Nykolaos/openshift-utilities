#!/bin/bash

# Script to gather OpenShift workload resource requests/limits, quotas/limit ranges, and node details

# Function to display script usage
usage() {
  echo "Usage: $0 [--workloads] [--quotas-limits] [--nodes] [--debug]"
  echo "  --workloads     : Gathers deployment, deploymentconfig, and statefulset resource requests and limits."
  echo "                    Converts CPU values to millicores (m) and memory values to mebibytes (Mi)."
  echo "                    Generates 'workload.csv' inside a timestamped 'resource-gather_YYYYMMDD_HHMMSS' folder."
  echo "  --quotas-limits : Gathers resource quota and limit range details for each namespace."
  echo "                    Resource Quotas: memory in Gi, CPU in cores. Limit Ranges: memory in Mi, CPU in m."
  echo "                    Generates 'quotas-limits.csv' inside a timestamped 'resource-gather_YYYYMMSS_HHMMSS' folder."
  echo "  --nodes         : Gathers total CPU/memory requests/limits, pod count, and node capacity for each node."
  echo "                    Converts node-level memory values to GiB and CPU values to cores."
  echo "                    Pod-level details will show memory in MiB and CPU in millicores."
  echo "                    Generates 'nodes.csv' inside a timestamped 'resource-gather_YYYYMMDD_HHMMSS' folder."
  echo "  --debug         : Prints detailed CSV data to stdout during execution."
  echo ""
  echo "Example: $0 --workloads"
  echo "Example: $0 --quotas-limits --debug"
  echo "Example: $0 --nodes"
  exit 1
}

# Check if oc command is available
if ! command -v oc &> /dev/null
then
    echo "Error: 'oc' command not found. Please ensure you are logged into an OpenShift cluster."
    exit 1
fi

# Check if jq command is available
if ! command -v jq &> /dev/null
then
    echo "Error: 'jq' command not found. Please install it (e.g., sudo yum install jq / sudo apt-get install jq)."
    exit 1
fi

# Check if bc command is available
if ! command -v bc &> /dev/null
then
    echo "Error: 'bc' command not found. Please install it (e.g., sudo yum install bc / sudo apt-get install bc)."
    exit 1
fi

# Initialize flags
WORKLOAD_OPTION_PRESENT=false
QUOTAS_OPTION_PRESENT=false
NODES_OPTION_PRESENT=false
DEBUG_MODE=false

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --workloads)
      WORKLOAD_OPTION_PRESENT=true
      ;;
    --quotas-limits)
      QUOTAS_OPTION_PRESENT=true
      ;;
    --nodes)
      NODES_OPTION_PRESENT=true
      ;;
    --debug)
      DEBUG_MODE=true
      ;;
    *)
      echo "Unknown option: $1"
      echo ""
      usage
      ;;
  esac
  shift
done

# If no options provided, print usage
if [ "$WORKLOAD_OPTION_PRESENT" = false ] && \
   [ "$QUOTAS_OPTION_PRESENT" = false ] && \
   [ "$NODES_OPTION_PRESENT" = false ]; then
  usage
fi

# Helper function to convert various memory units to bytes (for summation)
convert_memory_to_bytes() {
  local value_with_unit=$1
  if [ -z "$value_with_unit" ]; then
    echo "0"
    return
  fi

  # Use numfmt if available, for robustness
  if command -v numfmt &> /dev/null; then
    local bytes=$(numfmt --from=iec "$value_with_unit" 2>/dev/null)
    if [ -n "$bytes" ]; then
      echo "$bytes"
      return
    fi
  fi

  # Manual parsing if numfmt is not available or fails
  local num=$(echo "$value_with_unit" | sed -E 's/^([0-9.]+)([KMGTPEZY]i?B?)/\1/')
  local unit=$(echo "$value_with_unit" | sed -E 's/^([0-9.]+)([KMGTPEZY]i?B?)/\2/')
  local bytes=0

  case "$unit" in
    Ki|K|KiB) bytes=$(echo "scale=0; $num * 1024" | bc);;
    Mi|M|MiB) bytes=$(echo "scale=0; $num * 1024 * 1024" | bc);;
    Gi|G|GiB) bytes=$(echo "scale=0; $num * 1024 * 1024 * 1024" | bc);;
    Ti|T|TiB) bytes=$(echo "scale=0; $num * 1024 * 1024 * 1024 * 1024" | bc);;
    *) bytes=$(echo "scale=0; $num" | bc);; # Assume bytes if no unit or unknown unit
  esac
  echo "$bytes"
}

# Helper function to convert memory values (in any unit) to GiB and append unit (for bash context)
convert_memory_to_gib_bash() {
  local value_with_unit=$1
  if [ -z "$value_with_unit" ]; then
    echo ""
    return
  fi

  local mem_bytes=$(convert_memory_to_bytes "$value_with_unit")
  if [ -n "$mem_bytes" ] && [ "$mem_bytes" -gt 0 ]; then
    # Ensure bc is available for division
    if command -v bc &> /dev/null; then
      printf "%.2fGi" $(echo "scale=2; $mem_bytes / (1024 * 1024 * 1024)" | bc 2>/dev/null)
    else
      echo "$value_with_unit" # Fallback if bc is not available
    fi
  else
    echo ""
  fi
}

# Helper function to convert memory values (in any unit) to MiB and append unit (for bash context)
convert_memory_to_mib_bash() {
  local value_with_unit=$1
  if [ -z "$value" ]; then # Changed to $value from $value_with_unit
    echo ""
    return
  fi

  local mem_bytes=$(convert_memory_to_bytes "$value_with_unit")
  if [ -n "$mem_bytes" ] && [ "$mem_bytes" -gt 0 ]; then
    if command -v bc &> /dev/null; then
      printf "%.2fMi" $(echo "scale=2; $mem_bytes / (1024 * 1024)" | bc 2>/dev/null)
    else
      echo "$value_with_unit" # Fallback if bc is not available
    fi
  else
    echo ""
  fi
}


# Helper function to format CPU values to cores (for bash context)
format_cpu_cores_bash() {
  local value=$1
  if [ -z "$value" ]; then
    echo ""
    return
  fi

  if [[ "$value" =~ m$ ]]; then
    # Convert millicores to cores
    local cores=$(echo "scale=2; ${value%m} / 1000" | bc 2>/dev/null)
    printf "%.2fcores" "$cores"
  elif [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # If it's a number, assume cores and append " cores"
    echo "$value cores"
  else
    echo "$value" # Return as is if unknown format
  fi
}

# Helper function to format CPU values to millicores (for bash context)
format_cpu_m_bash() {
  local value=$1
  if [ -z "$value" ]; then
    echo ""
    return
  fi

  if [[ "$value" =~ m$ ]]; then
    echo "$value" # Already in millicores
  elif [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Convert cores to millicores
    local millicores=$(echo "scale=0; $value * 1000" | bc 2>/dev/null)
    printf "%dm" "$millicores"
  else
    echo "$value" # Return as is if unknown format
  fi
}


# --- Workload Resource Gathering Functions ---

# Function to get resource requests and limits for deployments, deploymentconfigs, statefulsets
get_workload_resources() {
  local namespace=$1
  local workload_type=$2
  local workload_name=$3

  # jq_filter to output values converted to 'm' for CPU and 'Mi' for Memory
  local jq_filter=$(cat <<'EOF_JQ_FILTER'
    # Generic memory parser to MiB. Assumes bytes if no unit provided.
    def parse_memory_to_mib(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>[KMGTPEZY]i?B?)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing
           (
             if $unit_str == "Ki" or $unit_str == "K" or $unit_str == "KiB" then $num / 1024
             elif $unit_str == "Mi" or $unit_str == "M" or $unit_str == "MiB" then $num
             elif $unit_str == "Gi" or $unit_str == "G" or $unit_str == "GiB" then $num * 1024
             elif $unit_str == "Ti" or $unit_str == "T" or $unit_str == "TiB" then $num * 1024 * 1024
             else $num / (1024*1024) # Assume bytes if no unit, convert to MiB
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # Generic CPU parser to millicores. Assumes cores if no unit provided.
    def parse_cpu_to_millicores(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>m)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing (implies cores)
           (
             if $unit_str == "m" then $num # Already millicores
             else $num * 1000 # Assume cores
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # Helper function to format memory values to MiB with units for workload resources
    def format_mem_mib_workload_new(value):
      if value == "" then ""
      else (parse_memory_to_mib(value) * 100 | round) / 100 | tostring + "Mi"
      end;

    # Helper function to format CPU values to millicores with 'm' unit for workload resources
    def format_cpu_m_workload_new(value):
      if value == "" then ""
      else (parse_cpu_to_millicores(value) | round) | tostring + "m"
      end;

    .spec.template.spec.containers[] |
    {
      containerName: .name,
      cpuRequest: (.resources.requests.cpu // ""),
      memoryRequest: (.resources.requests.memory // ""),
      cpuLimit: (.resources.limits.cpu // ""),
      memoryLimit: (.resources.limits.memory // "")
    } |
    [
      $namespace,
      $workload_type,
      $workload_name,
      .containerName,
      (format_cpu_m_workload_new(.cpuRequest)),
      (format_mem_mib_workload_new(.memoryRequest)),
      (format_cpu_m_workload_new(.cpuLimit)),
      (format_mem_mib_workload_new(.memoryLimit))
    ] | @csv
EOF_JQ_FILTER
)

  oc get "$workload_type" "$workload_name" -n "$namespace" -o json | \
    jq -r \
       --arg namespace "$namespace" \
       --arg workload_type "$workload_type" \
       --arg workload_name "$workload_name" \
       "$jq_filter"
}

# --- Quota and Limit Range Gathering Functions ---

# Function to get ResourceQuota details (now outputs a single row per quota)
get_resource_quota_details() {
  local namespace=$1
  local quota_name=$2

  # jq_filter to output raw values with original units (no conversion)
  local jq_filter=$(cat <<'EOF_JQ_FILTER'
    # Generic memory parser to MiB. Assumes bytes if no unit provided.
    def parse_memory_to_mib(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>[KMGTPEZY]i?B?)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing
           (
             if $unit_str == "Ki" or $unit_str == "K" or $unit_str == "KiB" then $num / 1024
             elif $unit_str == "Mi" or $unit_str == "M" or $unit_str == "MiB" then $num
             elif $unit_str == "Gi" or $unit_str == "G" or $unit_str == "GiB" then $num * 1024
             elif $unit_str == "Ti" or $unit_str == "T" or $unit_str == "TiB" then $num * 1024 * 1024
             else $num / (1024*1024) # Assume bytes if no unit, convert to MiB
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # Generic CPU parser to millicores. Assumes cores if no unit provided.
    def parse_cpu_to_millicores(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>m)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing (implies cores)
           (
             if $unit_str == "m" then $num # Already millicores
             else $num * 1000 # Assume cores
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # New formatters using the generic parsers
    def format_mem_gib_quota_new(value):
      if value == "" then ""
      else (parse_memory_to_mib(value) / 1024 * 100 | round) / 100 | tostring + "Gi"
      end;

    def format_cpu_cores_quota_new(value):
      if value == "" then ""
      else (parse_cpu_to_millicores(value) / 1000 * 100 | round) / 100 | tostring + "cores"
      end;

    {
      cpu_hard: (format_cpu_cores_quota_new((.spec.hard.cpu // "") // "")),
      cpu_used: (format_cpu_cores_quota_new((.status.used.cpu // "") // "")),

      memory_hard: (format_mem_gib_quota_new((.spec.hard.memory // "") // "")),
      memory_used: (format_mem_gib_quota_new((.status.used.memory // "") // "")),

      pods_hard: ((.spec.hard.pods // "") // ""),
      pods_used: ((.status.used.pods // "") // ""),

      requests_cpu_hard: (format_cpu_cores_quota_new((.spec.hard."requests.cpu" // "") // "")),
      requests_cpu_used: (format_cpu_cores_quota_new((.status.used."requests.cpu" // "") // "")),

      requests_memory_hard: (format_mem_gib_quota_new((.spec.hard."requests.memory" // "") // "")),
      requests_memory_used: (format_mem_gib_quota_new((.status.used."requests.memory" // "") // "")),

      limits_cpu_hard: (format_cpu_cores_quota_new((.spec.hard."limits.cpu" // "") // "")),
      limits_cpu_used: (format_cpu_cores_quota_new((.status.used."limits.cpu" // "") // "")),

      limits_memory_hard: (format_mem_gib_quota_new((.spec.hard."limits.memory" // "") // "")),
      limits_memory_used: (format_mem_gib_quota_new((.status.used."limits.memory" // "") // "")),

      persistentvolumeclaims_hard: ((.spec.hard.persistentvolumeclaims // "") // ""),
      persistentvolumeclaims_used: ((.status.used.persistentvolumeclaims // "") // ""),

      requests_storage_hard: (format_mem_gib_quota_new((.spec.hard."requests.storage" // "") // "")),
      requests_storage_used: (format_mem_gib_quota_new((.status.used."requests.storage" // "") // "")),

      configmaps_hard: ((.spec.hard.configmaps // "") // ""),
      configmaps_used: ((.status.used.configmaps // "") // ""),

      secrets_hard: ((.spec.hard.secrets // "") // ""),
      secrets_used: ((.status.used.secrets // "") // ""),

      services_hard: ((.spec.hard.services // "") // ""),
      services_used: ((.status.used.services // "") // "")
    } |
    [
      $namespace,
      $quota_name,
      .cpu_hard, .cpu_used,
      .memory_hard, .memory_used,
      .pods_hard, .pods_used,
      .requests_cpu_hard, .requests_cpu_used,
      .requests_memory_hard, .requests_memory_used,
      .limits_cpu_hard, .limits_cpu_used,
      .limits_memory_hard, .limits_memory_used,
      .persistentvolumeclaims_hard, .persistentvolumeclaims_used,
      .requests_storage_hard, .requests_storage_used,
      .configmaps_hard, .configmaps_used,
      .secrets_hard, .secrets_used,
      .services_hard, .services_used
    ] | @csv
EOF_JQ_FILTER
)

  local quota_json
  quota_json=$(oc get resourcequota "$quota_name" -n "$namespace" -o json 2>/dev/null)

  if [ -n "$quota_json" ]; then
    if echo "$quota_json" | jq -e . >/dev/null 2>&1; then
      echo "$quota_json" | jq -r \
        --arg namespace "$namespace" \
        --arg quota_name "$quota_name" \
        "$jq_filter"
    fi
  fi
}

# Function to get LimitRange details
get_limit_range_details() {
  local namespace=$1
  local limitrange_name=$2

  # jq_filter to output raw values with original units (no conversion)
  local jq_filter=$(cat <<'EOF_JQ_FILTER'
    # Generic memory parser to MiB. Assumes bytes if no unit provided.
    def parse_memory_to_mib(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>[KMGTPEZY]i?B?)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing
           (
             if $unit_str == "Ki" or $unit_str == "K" or $unit_str == "KiB" then $num / 1024
             elif $unit_str == "Mi" or $unit_str == "M" or $unit_str == "MiB" then $num
             elif $unit_str == "Gi" or $unit_str == "G" or $unit_str == "GiB" then $num * 1024
             elif $unit_str == "Ti" or $unit_str == "T" or $unit_str == "TiB" then $num * 1024 * 1024
             else $num / (1024*1024) # Assume bytes if no unit, convert to MiB
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # Generic CPU parser to millicores. Assumes cores if no unit provided.
    def parse_cpu_to_millicores(value):
      if value == "" then 0
      else
        (value | capture("^(?<num>[0-9.]+)(?<unit>m)?$") as $captured |
         if $captured.num? then
           ($captured.num | tonumber? // 0) as $num |
           ($captured.unit? // "") as $unit_str | # Default unit to empty string if missing (implies cores)
           (
             if $unit_str == "m" then $num # Already millicores
             else $num * 1000 # Assume cores
             end
           )
         else
           0 # Invalid number format
         end
        )
      end;

    # New formatters using the generic parsers
    def format_mem_mib_lr_new(value):
      if value == "" then ""
      else (parse_memory_to_mib(value) * 100 | round) / 100 | tostring + "Mi"
      end;

    def format_cpu_m_lr_new(value):
      if value == "" then ""
      else (parse_cpu_to_millicores(value) | round) | tostring + "m"
      end;

    reduce .spec.limits[] as $item ({}; .[$item.type] = $item) |
    {
      container_defaultCpuRequest: (format_cpu_m_lr_new(((( .Container // {}).defaultRequest // {}).cpu // "") // "")),
      container_defaultMemoryRequest: (format_mem_mib_lr_new(((( .Container // {}).defaultRequest // {}).memory // "") // "")),
      container_defaultCpuLimit: (format_cpu_m_lr_new(((( .Container // {}).default // {}).cpu // "") // "")),
      container_defaultMemoryLimit: (format_mem_mib_lr_new(((( .Container // {}).default // {}).memory // "") // "")),
      container_maxCpu: (format_cpu_m_lr_new((( .Container // {}).max // {}).cpu // "")),
      container_maxMemory: (format_mem_mib_lr_new((( .Container // {}).max // {}).memory // "")),
      container_minCpu: (format_cpu_m_lr_new((( .Container // {}).min // {}).cpu // "")),
      container_minMemory: (format_mem_mib_lr_new((( .Container // {}).min // {}).memory // "")),

      pod_maxCpu: (format_cpu_m_lr_new((( .Pod // {}).max // {}).cpu // "")),
      pod_maxMemory: (format_mem_mib_lr_new((( .Pod // {}).max // {}).memory // "")),
      pod_minCpu: (format_cpu_m_lr_new((( .Pod // {}).min // {}).cpu // "")),
      pod_minMemory: (format_mem_mib_lr_new((( .Pod // {}).min // {}).memory // "")),
      pod_defaultCpuRequest: (format_cpu_m_lr_new((( .Pod // {}).defaultRequest // {}).cpu // "")),
      pod_defaultMemoryRequest: (format_mem_mib_lr_new((( .Pod // {}).defaultRequest // {}).memory // "")),
      pod_defaultCpuLimit: (format_cpu_m_lr_new((( .Pod // {}).default // {}).cpu // "")),
      pod_defaultMemoryLimit: (format_mem_mib_lr_new((( .Pod // {}).default // {}).memory // "")),

      pvc_defaultStorage: (format_mem_mib_lr_new((( .PersistentVolumeClaim // {}).default // {}).storage // "")),
      pvc_maxStorage: (format_mem_mib_lr_new((( .PersistentVolumeClaim // {}).max // {}).storage // ""))
    } |
    [
      $namespace,
      $limitrange_name,
      .container_defaultCpuRequest, .container_defaultMemoryRequest,
      .container_defaultCpuLimit, .container_defaultMemoryLimit,
      .container_maxCpu, .container_maxMemory,
      .container_minCpu, .container_minMemory,
      .pod_maxCpu, .pod_maxMemory,
      .pod_minCpu, .pod_minMemory,
      .pod_defaultCpuRequest, .pod_defaultMemoryRequest,
      .pod_defaultCpuLimit, .pod_defaultMemoryLimit,
      .pvc_defaultStorage, .pvc_maxStorage
    ] | @csv
EOF_JQ_FILTER
)

  oc get limitrange "$limitrange_name" -n "$namespace" -o json | \
    jq -r \
       --arg namespace "$namespace" \
       --arg limitrange_name "$limitrange_name" \
       "$jq_filter"
}

# --- Node Resource Gathering Functions ---

# Function to get node details: total requests, total limits, pod count, and capacity
# This function now outputs a multi-line string containing node summary and pod details, with converted units.
get_node_details() {
  local node_name=$1
  local node_json_output
  node_json_output=$(oc get node "$node_name" -o json 2>/dev/null)

  local cpu_req=""
  local cpu_limit=""
  local mem_req_raw=""
  local mem_limit_raw=""
  local num_pods=""
  local cpu_capacity_raw=""
  local mem_capacity_raw=""

  # Get capacity from JSON output (more reliable)
  if [ -n "$node_json_output" ]; then
    cpu_capacity_raw=$(echo "$node_json_output" | jq -r '.status.capacity.cpu // ""')
    mem_capacity_raw=$(echo "$node_json_output" | jq -r '.status.capacity.memory // ""')
  fi

  # Convert node-level memory capacity to GiB
  local mem_capacity_formatted=$(convert_memory_to_gib_bash "$mem_capacity_raw")

  # Convert node-level CPU capacity to cores
  local cpu_capacity_formatted=$(format_cpu_cores_bash "$cpu_capacity_raw")

  # Extract "Allocated resources" from oc describe node for accurate requests/limits and pod count
  local node_describe_output=$(oc describe node "$node_name" 2>/dev/null)
  if [ -n "$node_describe_output" ]; then
    local allocated_resources_block=$(echo "$node_describe_output" | awk '
      /^Allocated resources:/ {in_block=1; next}
      /^Events:/ {in_block=0}
      in_block {
        if ($0 !~ /Total limits may exceed allocatable resources/ && $0 !~ /Resource           Requests         Limits/) {
          print
        }
      }'
    )

    while IFS= read -r line; do
      if echo "$line" | grep -q "cpu"; then
        cpu_req=$(echo "$line" | awk '{print $2}')
        cpu_limit=$(echo "$line" | awk '{print $4}')
      elif echo "$line" | grep -q "memory"; then
        mem_req_raw=$(echo "$line" | awk '{print $2}')
        mem_limit_raw=$(echo "$line" | awk '{print $4}')
      fi
    done <<< "$allocated_resources_block"

    # Extract the "Non-terminated Pods" line and get the count
    local pods_line=$(echo "$node_describe_output" | grep "Non-terminated Pods:")
    if [[ "$pods_line" =~ \(([0-9]+)\ in\ total\) ]]; then
        num_pods=${BASH_REMATCH[1]} # This extracts the number inside the parentheses
    else
        num_pods="0" # Default to 0 if not found or not in expected format
    fi

    # Extract the "Non-terminated Pods" block for detailed pod info
    local non_terminated_pods_block=$(echo "$node_describe_output" | awk '
      /^Non-terminated Pods:/ {in_block=1; next}
      /^Allocated resources:/ {in_block=0}
      in_block {
        # Skip the header line (e.g., "Namespace    Name ...") and lines with only dashes
        if ($0 !~ /Namespace\s+Name\s+CPU Requests/ && $0 !~ /^--*$/) {
          print
        }
      }'
    )
  fi

  # Convert node-level memory request and limit to GiB and CPU to cores
  local mem_req_formatted=$(convert_memory_to_gib_bash "$mem_req_raw")
  local mem_limit_formatted=$(convert_memory_to_gib_bash "$mem_limit_raw")
  local cpu_req_formatted=$(format_cpu_cores_bash "$cpu_req")
  local cpu_limit_formatted=$(format_cpu_cores_bash "$cpu_limit")


  # Build the node summary line
  local node_summary_line="\"$cpu_req_formatted\",\"$cpu_limit_formatted\",\"$mem_req_formatted\",\"$mem_limit_formatted\",\"$cpu_capacity_formatted\",\"$mem_capacity_formatted\",\"$num_pods\""

  local pod_details_output=""
  # Parse each line from the non_terminated_pods_block
  while IFS= read -r pod_line; do
    if [ -n "$pod_line" ]; then # Ensure the line is not empty
      local ns_name=$(echo "$pod_line" | awk '{print $1}')
      local p_name=$(echo "$pod_line" | awk '{print $2}')
      local cpu_req_raw=$(echo "$pod_line" | awk '{print $3}' | sed 's/([^)]*)//g' | tr -d '[:space:]') # Remove percentage and spaces
      local cpu_limit_raw=$(echo "$pod_line" | awk '{print $4}' | sed 's/([^)]*)//g' | tr -d '[:space:]')
      local mem_req_raw=$(echo "$pod_line" | awk '{print $5}' | sed 's/([^)]*)//g' | tr -d '[:space:]')
      local mem_limit_raw=$(echo "$pod_line" | awk '{print $6}' | sed 's/([^)]*)//g' | tr -d '[:space:]')

      # Convert pod CPU to millicores and memory to MiB
      local p_cpu_req_formatted=$(format_cpu_m_bash "$cpu_req_raw")
      local p_cpu_limit_formatted=$(format_cpu_m_bash "$cpu_limit_raw")
      local p_mem_req_formatted=$(convert_memory_to_mib_bash "$mem_req_raw")
      local p_mem_limit_formatted=$(convert_memory_to_mib_bash "$mem_limit_raw")

      pod_details_output+="\n\"$ns_name\",\"$p_name\",\"$p_cpu_req_formatted\",\"$p_cpu_limit_formatted\",\"$p_mem_req_formatted\",\"$p_mem_limit_formatted\""
    fi
  done <<< "$non_terminated_pods_block"

  # Return the node summary line followed by pod details structure
  echo -e "$node_summary_line\n# --- Pods ---\nNamespace,PodName,CPURequest,CPULimit,MemRequest,MemLimit$pod_details_output"
}

# Get namespaces (used for workload/quotas)
# Using 'oc get projects' for OpenShift specific project listing.
NAMESPACES=$(oc get projects -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

# Get node names
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)


# Define the base output directory with timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="resource-gather_${TIMESTAMP}"

# Create the output directory
mkdir -p "$OUTPUT_DIR"

if [ "$WORKLOAD_OPTION_PRESENT" = true ]; then
  WORKLOAD_OUTPUT_FILE="${OUTPUT_DIR}/workload.csv"
  # Updated header with specific units for workloads in CamelCase
  WORKLOAD_CSV_HEADER="Namespace,WorkloadType,WorkloadName,ContainerName,CpuRequest (m),MemoryRequest (Mi),CpuLimit (m),MemoryLimit (Mi)"

  echo "$WORKLOAD_CSV_HEADER" > "$WORKLOAD_OUTPUT_FILE"
  echo "Gathering workload resource requests and limits. Output will be saved to '$WORKLOAD_OUTPUT_FILE'."
  echo "" # Newline for readability

  if [ "$DEBUG_MODE" = true ]; then
    echo "$WORKLOAD_CSV_HEADER" # Print header only in debug mode
  fi

  for NS in $NAMESPACES; do
    # Get Deployments
    DEPLOYMENTS=$(oc get deployments -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for DEPLOYMENT in $DEPLOYMENTS; do
      RESOURCE_DATA=$(get_workload_resources "$NS" "deployment" "$DEPLOYMENT")
      if [ -n "$RESOURCE_DATA" ]; then
        echo "$RESOURCE_DATA" >> "$WORKLOAD_OUTPUT_FILE"
        if [ "$DEBUG_MODE" = true ]; then # Only print to stdout if debug mode is on
          echo "$RESOURCE_DATA"
        fi
      fi
    done

    # Get DeploymentConfigs
    DEPLOYMENTCONFIGS=$(oc get deploymentconfigs -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for DC in $DEPLOYMENTCONFIGS; do
      RESOURCE_DATA=$(get_workload_resources "$NS" "deploymentconfig" "$DC")
      if [ -n "$RESOURCE_DATA" ]; then
        echo "$RESOURCE_DATA" >> "$WORKLOAD_OUTPUT_FILE"
        if [ "$DEBUG_MODE" = true ]; then # Only print to stdout if debug mode is on
          echo "$RESOURCE_DATA"
        fi
      fi
    done

    # Get StatefulSets
    STATEFULSETS=$(oc get statefulsets -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for STS in $STATEFULSETS; do
      RESOURCE_DATA=$(get_workload_resources "$NS" "statefulset" "$STS")
      if [ -n "$RESOURCE_DATA" ]; then
        echo "$RESOURCE_DATA" >> "$WORKLOAD_OUTPUT_FILE"
        if [ "$DEBUG_MODE" = true ]; then # Only print to stdout if debug mode is on
          echo "$RESOURCE_DATA"
        fi
      fi
    done
  done
  echo ""
  echo "Workload data collection complete. Output saved to '$WORKLOAD_OUTPUT_FILE'."
fi

if [ "$QUOTAS_OPTION_PRESENT" = true ]; then
  QUOTAS_OUTPUT_FILE="${OUTPUT_DIR}/quotas-limits.csv"
  
  # Define header for Resource Quotas with specific units in CamelCase
  QUOTA_CSV_HEADER="Namespace,QuotaName,CpuHard (cores),CpuUsed (cores),MemoryHard (Gi),MemoryUsed (Gi),PodsHard,PodsUsed,RequestsCpuHard (cores),RequestsCpuUsed (cores),RequestsMemoryHard (Gi),RequestsMemoryUsed (Gi),LimitsCpuHard (cores),LimitsCpuUsed (cores),LimitsMemoryHard (Gi),LimitsMemoryUsed (Gi),PvcsHard,PvcsUsed,RequestsStorageHard (Gi),RequestsStorageUsed (Gi),ConfigMapsHard,ConfigMapsUsed,SecretsHard,SecretsUsed,ServicesHard,ServicesUsed"

  # Define header for Limit Ranges with specific units in CamelCase
  LIMITRANGE_CSV_HEADER="Namespace,LimitRangeName,ContainerDefaultCpuRequest (m),ContainerDefaultMemoryRequest (Mi),ContainerDefaultCpuLimit (m),ContainerDefaultMemoryLimit (Mi),ContainerMaxCpu (m),ContainerMaxMemory (Mi),ContainerMinCpu (m),ContainerMinMemory (Mi),PodMaxCpu (m),PodMaxMemory (Mi),PodMinCpu (m),PodMinMemory (Mi),PodDefaultCpuRequest (m),PodDefaultMemoryRequest (Mi),PodDefaultCpuLimit (m),PodDefaultMemoryLimit (Mi),PvcDefaultStorage (Mi),PvcMaxStorage (Mi)"


  # --- File Output Logic for Quotas and Limit Ranges ---

  # 1. Start file with Quota Header
  echo "# --- Resource Quotas ---" > "$QUOTAS_OUTPUT_FILE"
  echo "$QUOTA_CSV_HEADER" >> "$QUOTAS_OUTPUT_FILE"
  echo "Gathering resource quota and limit range details. Output will be saved to '$QUOTAS_OUTPUT_FILE'."
  echo "" # Newline for readability

  if [ "$DEBUG_MODE" = true ]; then
    echo "--- Resource Quotas ---" # Print header only in debug mode
    echo "$QUOTA_CSV_HEADER"      # Print header only in debug mode
  fi

  # 3. Collect and append Resource Quota data to file and stdout
  for NS in $NAMESPACES; do
    RESOURCE_QUOTAS=$(oc get resourcequotas -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for RQ in $RESOURCE_QUOTAS; do
      QUOTA_DATA=$(get_resource_quota_details "$NS" "$RQ")
      if [ -n "$QUOTA_DATA" ]; then
        echo "$QUOTA_DATA" >> "$QUOTAS_OUTPUT_FILE"
        if [ "$DEBUG_MODE" = true ]; then # Only print to stdout if debug mode is on
          echo "$QUOTA_DATA"
        fi
      fi
    done
  done

  # 4. Append separator and Limit Range Header to the file
  echo "# --- Limit Ranges ---" >> "$QUOTAS_OUTPUT_FILE"
  echo "$LIMITRANGE_CSV_HEADER" >> "$QUOTAS_OUTPUT_FILE"

  if [ "$DEBUG_MODE" = true ]; then
    echo "" # Add a blank line for readability in console output
    echo "--- Limit Ranges ---"   # Print header only in debug mode
    echo "$LIMITRANGE_CSV_HEADER" # Print header only in debug mode
  fi

  # 6. Collect and append Limit Range data to file and stdout
  for NS in $NAMESPACES; do
    LIMIT_RANGES=$(oc get limitranges -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for LR in $LIMIT_RANGES; do
      LIMIT_DATA=$(get_limit_range_details "$NS" "$LR")
      if [ -n "$LIMIT_DATA" ]; then
        echo "$LIMIT_DATA" >> "$QUOTAS_OUTPUT_FILE"
        if [ "$DEBUG_MODE" = true ]; then # Only print to stdout if debug mode is on
          echo "$LIMIT_DATA"
        fi
      fi
    done
  done

  echo ""
  echo "Quotas and Limit Ranges data collection complete. Output saved to '$QUOTAS_OUTPUT_FILE'."
fi

if [ "$NODES_OPTION_PRESENT" = true ]; then
  NODES_OUTPUT_FILE="${OUTPUT_DIR}/nodes.csv"
  # Define header for node data with specific units
  NODE_SUMMARY_CSV_HEADER="CpuRequest (cores),CpuLimit (cores),MemoryRequest (Gi),MemoryLimit (Gi),CpuCapacity (cores),MemoryCapacity (Gi),PodsCount" 
  POD_DETAILS_CSV_HEADER="Namespace,PodName,CpuRequest (m),CpuLimit (m),MemRequest (Mi),MemLimit (Mi)" # Updated header for Pods

  echo "Gathering node resource requests, limits, and pod counts. Output will be saved to '$NODES_OUTPUT_FILE'."
  echo "" # Newline for readability

  if [ "$DEBUG_MODE" = true ]; then
    echo "--- Node Details ---" # Print header only in debug mode
  fi

  # Loop through nodes and format output as requested
  for NODE in "$NODES"; do # Iterate over NODES correctly
    # Node Name Header
    echo "# --- $NODE ---" >> "$NODES_OUTPUT_FILE"
    # Node Summary Headers
    echo "$NODE_SUMMARY_CSV_HEADER" >> "$NODES_OUTPUT_FILE"
    
    if [ "$DEBUG_MODE" = true ]; then
      echo "# --- $NODE ---"
      echo "$NODE_SUMMARY_CSV_HEADER"
    fi

    # get_node_details will now return a multi-line string containing node summary and pod details
    NODE_AND_POD_DATA=$(get_node_details "$NODE")
    if [ -n "$NODE_AND_POD_DATA" ]; then
      echo "$NODE_AND_POD_DATA" >> "$NODES_OUTPUT_FILE"
      if [ "$DEBUG_MODE" = true ]; then
        echo "$NODE_AND_POD_DATA"
      fi
    fi

    # Add 3 empty rows after each node's block
    echo "" >> "$NODES_OUTPUT_FILE"
    echo "" >> "$NODES_OUTPUT_FILE"
    echo "" >> "$NODES_OUTPUT_FILE"

    if [ "$DEBUG_MODE" = true ]; then
      echo ""
      echo ""
      echo ""
    fi
  done
  echo ""
  echo "Node data collection complete. Output saved to '$NODES_OUTPUT_FILE'."
fi

echo ""
echo "Script execution finished."
