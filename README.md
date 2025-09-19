# openshift-utilities
A utility script to collect OpenShift cluster resource data into CSV files. It can gather:

- Workload container requests and limits
- ResourceQuotas and LimitRanges
- Node-level requests, limits, capacity, and pod breakdown
- Persistent Volume details with related workloads

Outputs are organized under a timestamped folder like resource-gather_YYYYMMDD_HHMMSS.

Please refer to the tag section for stable version (the python script is still in development).

## Features

- Workloads: Deployments, DeploymentConfigs, StatefulSets
    - CPU converted to millicores (m), memory to Mi
    - Per-container rows
- Quotas and Limits:
    - ResourceQuotas summarized with CPU in cores and memory in Gi
    - LimitRanges summarized with CPU in m and memory in Mi
- Nodes:
    - Node summaries in cores and Gi
    - Pod-level details in m and Mi
- Volumes:
    - PV size, PVC details, access modes
    - Related workload kind/name and an inferred pod count

## Requirements

- Access to an OpenShift cluster and logged in with oc
- Tools on your local machine:
    - oc (OpenShift CLI)
    - jq
    - bc
    - numfmt (optional, used for robust unit parsing if present)
- Bash shell

## Usage

Run the script with one or more options. A new output directory will be created for each run.

- ./[resource-gather.sh](http://resource-gather.sh) --workloads
- ./[resource-gather.sh](http://resource-gather.sh) --quotas-limits
- ./[resource-gather.sh](http://resource-gather.sh) --nodes
- ./[resource-gather.sh](http://resource-gather.sh) --volumes
- ./[resource-gather.sh](http://resource-gather.sh) --quotas-limits --debug

Options:

- --workloads
    - Scans all projects for Deployments, DeploymentConfigs, StatefulSets
    - Outputs workload.csv with columns:
        - Namespace
        - WorkloadType
        - WorkloadName
        - ContainerName
        - CpuRequest (m)
        - MemoryRequest (Mi)
        - CpuLimit (m)
        - MemoryLimit (Mi)
- --quotas-limits
    - Resource Quotas section (cores, Gi) and Limit Ranges section (m, Mi)
    - Outputs quotas-limits.csv with two sections:
        - Resource Quotas header and rows
        - Limit Ranges header and rows
- --nodes
    - For each node:
        - Summary of CPU/Memory Requests and Limits, Capacity, and Pods count
        - Detailed pod lines with per-pod CPU/Memory requests and limits
    - Outputs nodes.csv, organized per node with a “# --- Pods ---” section
- --volumes
    - Scans all PVs
    - Resolves PVC namespace/name, PV size, access modes, and related workloads
    - Estimates pod count based on workload status when applicable
    - Outputs volumes.csv with columns:
        - PVName
        - PVCName
        - PVCNamespace
        - PVSize
        - AccessMode
        - PodCount
        - RelatedWorkload
- --debug
    - Prints CSV lines to stdout as they are generated

If no options are provided, usage help is shown.

## Output Structure

- resource-gather_YYYYMMDD_HHMMSS/
    - workload.csv (when using --workloads)
    - quotas-limits.csv (when using --quotas-limits)
        - Section “# --- Resource Quotas ---”
        - Section “# --- Limit Ranges ---”
    - nodes.csv (when using --nodes)
        - For each node:
            - “# --- <node-name> ---”
            - Node summary header and a single summary row
            - “# --- Pods ---”
            - Pod details header and rows
    - volumes.csv (when using --volumes)

## Notes on Units and Parsing

- CPU:
    - Workload and pod details are in millicores (e.g., 250m)
    - Node summaries are in cores with two decimal places where applicable
- Memory:
    - Workload and pod details are in Mi
    - Node summaries are in Gi with two decimal places
- The script uses jq and bc for unit parsing and calculations
- numfmt is used opportunistically for robust conversions when available

## Permissions and Scope

- The script lists:
    - Projects, nodes, PVs across the cluster
    - Workloads, quotas, and limit ranges per namespace
- Your current oc context and RBAC determine visibility. For incomplete results, ensure your user has sufficient permissions and is logged into the right cluster and project set.

## Compatibility

- Designed for OpenShift environments
- Tested with standard oc outputs; minor differences across versions may require adjustments
