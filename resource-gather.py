import argparse
import subprocess
import json
import os
import csv
from datetime import datetime
import re

# Helper function to run shell commands
def run_command(command, check_output=True, ignore_errors=False):
    try:
        if check_output:
            result = subprocess.run(command, capture_output=True, text=True, check=True, shell=True)
            return result.stdout.strip()
        else:
            subprocess.run(command, check=True, shell=True)
            return True
    except subprocess.CalledProcessError as e:
        if not ignore_errors:
            print(f"Error executing command: {e.cmd}")
            print(f"Stdout: {e.stdout}")
            print(f"Stderr: {e.stderr}")
            raise
        return None
    except FileNotFoundError:
        if not ignore_errors:
            print(f"Command not found: {command.split()[0]}")
            raise
        return None

# Helper function to check for required commands
def check_prerequisites():
    required_commands = ['oc', 'jq', 'bc']
    for cmd in required_commands:
        if not run_command(f"command -v {cmd}", check_output=False, ignore_errors=True):
            print(f"Error: '{cmd}' command not found. Please install it or ensure it's in your PATH.")
            exit(1)

# --- Unit Conversion and Formatting Functions (Python equivalents) ---

def convert_memory_to_bytes(value_with_unit):
    if not value_with_unit:
        return 0

    # Try numfmt first if available
    try:
        bytes_val = run_command(f"numfmt --from=iec {value_with_unit}", ignore_errors=True)
        if bytes_val:
            return int(float(bytes_val)) # numfmt can return float for some inputs
    except Exception:
        pass # Fallback to manual parsing if numfmt fails

    # Manual parsing
    match = re.match(r"^([0-9.]+)([KMGTPEZY]i?B?)?$", value_with_unit)
    if not match:
        return 0

    num = float(match.group(1))
    unit = (match.group(2) or "").lower()

    if unit in ['ki', 'k', 'kib']:
        return int(num * 1024)
    elif unit in ['mi', 'm', 'mib']:
        return int(num * 1024 * 1024)
    elif unit in ['gi', 'g', 'gib']:
        return int(num * 1024 * 1024 * 1024)
    elif unit in ['ti', 't', 'tib']:
        return int(num * 1024 * 1024 * 1024 * 1024)
    else:
        return int(num) # Assume bytes if no unit or unknown unit

def convert_memory_to_gib(value_with_unit):
    mem_bytes = convert_memory_to_bytes(value_with_unit)
    if mem_bytes <= 0:
        return ""
    gib = mem_bytes / (1024 * 1024 * 1024)
    return f"{gib:.2f}Gi"

def convert_memory_to_mib(value_with_unit):
    mem_bytes = convert_memory_to_bytes(value_with_unit)
    if mem_bytes <= 0:
        return ""
    mib = mem_bytes / (1024 * 1024)
    return f"{mib:.0f}Mi" # Removed decimal points

def format_cpu_cores(value):
    if not value:
        return ""
    if value.endswith('m'):
        millicores = float(value[:-1])
        cores = millicores / 1000
        return f"{cores:.2f}cores"
    else:
        try:
            float(value) # Check if it's a valid number
            return f"{float(value):.2f}cores" # Assume cores if no unit
        except ValueError:
            return value

def format_cpu_m(value):
    if not value:
        return ""
    if value.endswith('m'):
        return value
    else:
        try:
            cores = float(value)
            millicores = int(round(cores * 1000))
            return f"{millicores}m"
        except ValueError:
            return value

# --- Workload Resource Gathering Functions ---

def get_workload_resources(namespace, workload_type, workload_name):
    try:
        json_output = run_command(f"oc get {workload_type} {workload_name} -n {namespace} -o json")
        data = json.loads(json_output)
    except Exception:
        return []

    rows = []
    containers = data.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])

    for container in containers:
        container_name = container.get('name', '')
        resources = container.get('resources', {})
        requests = resources.get('requests', {})
        limits = resources.get('limits', {})

        cpu_request = format_cpu_m(requests.get('cpu', ''))
        memory_request = convert_memory_to_mib(requests.get('memory', ''))
        cpu_limit = format_cpu_m(limits.get('cpu', ''))
        memory_limit = convert_memory_to_mib(limits.get('memory', ''))

        rows.append([
            namespace,
            workload_type,
            workload_name,
            container_name,
            cpu_request,
            memory_request,
            cpu_limit,
            memory_limit
        ])
    return rows

# --- Quota and Limit Range Gathering Functions ---

def get_resource_quota_details(namespace, quota_name):
    try:
        json_output = run_command(f"oc get resourcequota {quota_name} -n {namespace} -o json")
        data = json.loads(json_output)
    except Exception:
        return None

    spec_hard = data.get('spec', {}).get('hard', {})
    status_used = data.get('status', {}).get('used', {})

    # The fields cpu_hard, cpu_used, memory_hard, memory_used were removed as they are not typically present directly
    row = [
        namespace,
        quota_name,
        spec_hard.get('pods', ''),
        status_used.get('pods', ''),
        format_cpu_cores(spec_hard.get('requests.cpu', '')),
        format_cpu_cores(status_used.get('requests.cpu', '')),
        convert_memory_to_gib(spec_hard.get('requests.memory', '')),
        convert_memory_to_gib(status_used.get('requests.memory', '')),
        format_cpu_cores(spec_hard.get('limits.cpu', '')),
        format_cpu_cores(status_used.get('limits.cpu', '')),
        convert_memory_to_gib(spec_hard.get('limits.memory', '')),
        convert_memory_to_gib(status_used.get('limits.memory', '')),
        spec_hard.get('persistentvolumeclaims', ''),
        status_used.get('persistentvolumeclaims', ''),
        convert_memory_to_gib(spec_hard.get('requests.storage', '')),
        convert_memory_to_gib(status_used.get('requests.storage', '')),
        spec_hard.get('configmaps', ''),
        status_used.get('configmaps', ''),
        spec_hard.get('secrets', ''),
        status_used.get('secrets', ''),
        spec_hard.get('services', ''),
        status_used.get('services', '')
    ]
    return row

def get_limit_range_details(namespace, limitrange_name):
    try:
        json_output = run_command(f"oc get limitrange {limitrange_name} -n {namespace} -o json")
        data = json.loads(json_output)
    except Exception:
        return None

    limits_map = {}
    for item in data.get('spec', {}).get('limits', []):
        limits_map[item.get('type')] = item

    container_limits = limits_map.get('Container', {})
    pod_limits = limits_map.get('Pod', {})
    pvc_limits = limits_map.get('PersistentVolumeClaim', {})

    row = [
        namespace,
        limitrange_name,
        format_cpu_m(container_limits.get('defaultRequest', {}).get('cpu', '')),
        convert_memory_to_mib(container_limits.get('defaultRequest', {}).get('memory', '')),
        format_cpu_m(container_limits.get('default', {}).get('cpu', '')),
        convert_memory_to_mib(container_limits.get('default', {}).get('memory', '')),
        format_cpu_m(container_limits.get('max', {}).get('cpu', '')),
        convert_memory_to_mib(container_limits.get('max', {}).get('memory', '')),
        format_cpu_m(container_limits.get('min', {}).get('cpu', '')),
        convert_memory_to_mib(container_limits.get('min', {}).get('memory', '')),

        format_cpu_m(pod_limits.get('max', {}).get('cpu', '')),
        convert_memory_to_mib(pod_limits.get('max', {}).get('memory', '')),
        format_cpu_m(pod_limits.get('min', {}).get('cpu', '')),
        convert_memory_to_mib(pod_limits.get('min', {}).get('memory', '')),
        format_cpu_m(pod_limits.get('defaultRequest', {}).get('cpu', '')),
        convert_memory_to_mib(pod_limits.get('defaultRequest', {}).get('memory', '')),
        format_cpu_m(pod_limits.get('default', {}).get('cpu', '')),
        convert_memory_to_mib(pod_limits.get('default', {}).get('memory', '')),

        convert_memory_to_mib(pvc_limits.get('default', {}).get('storage', '')),
        convert_memory_to_mib(pvc_limits.get('max', {}).get('storage', ''))
    ]
    return row

# --- Node Resource Gathering Functions ---

def get_node_details(node_name):
    node_summary_data = []
    pod_details_data = []

    try:
        node_json_output = run_command(f"oc get node {node_name} -o json")
        node_data = json.loads(node_json_output)
    except Exception:
        return None, None # Return None for both if node data can't be fetched

    cpu_capacity_raw = node_data.get('status', {}).get('capacity', {}).get('cpu', '')
    mem_capacity_raw = node_data.get('status', {}).get('capacity', {}).get('memory', '')

    mem_capacity_formatted = convert_memory_to_gib(mem_capacity_raw)
    cpu_capacity_formatted = format_cpu_cores(cpu_capacity_raw)

    node_describe_output = run_command(f"oc describe node {node_name}", ignore_errors=True)

    cpu_req, cpu_limit, mem_req_raw, mem_limit_raw, num_pods = "", "", "", "", "0"

    if node_describe_output:
        # Extract allocated resources
        allocated_resources_block = []
        in_block = False
        for line in node_describe_output.splitlines():
            if "Allocated resources:" in line:
                in_block = True
                continue
            if "Events:" in line:
                in_block = False
            if in_block and "Total limits may exceed allocatable resources" not in line and "Resource           Requests         Limits" not in line:
                allocated_resources_block.append(line.strip())

        for line in allocated_resources_block:
            parts = line.split()
            if "cpu" in parts:
                cpu_req = parts[1] if len(parts) > 1 else ""
                cpu_limit = parts[3] if len(parts) > 3 else ""
            elif "memory" in parts:
                mem_req_raw = parts[1] if len(parts) > 1 else ""
                mem_limit_raw = parts[3] if len(parts) > 3 else ""
        
        # Extract non-terminated pods count
        pods_match = re.search(r"Non-terminated Pods:\s*\([0-9]+\s*in\s*total\)", node_describe_output)
        if pods_match:
            num_pods_line = pods_match.group(0)
            num_pods_match = re.search(r"\(([0-9]+)\s*in\s*total\)", num_pods_line)
            if num_pods_match:
                num_pods = num_pods_match.group(1)

        # Extract non-terminated pods details
        non_terminated_pods_block = []
        in_pods_block = False
        lines_skipped = 0
        for line in node_describe_output.splitlines():
            if "Non-terminated Pods:" in line:
                in_pods_block = True
                lines_skipped = 0 # Reset for new block
                continue
            if "Allocated resources:" in line: # Stop when hitting the next section
                in_pods_block = False
            if in_pods_block:
                if lines_skipped < 2: # Skip header and dashes
                    lines_skipped += 1
                    continue
                non_terminated_pods_block.append(line.strip())

        for pod_line in non_terminated_pods_block:
            if not pod_line:
                continue
            parts = pod_line.split()
            if len(parts) >= 9: # Ensure enough columns for parsing
                ns_name = parts[0]
                p_name = parts[1]
                p_cpu_req_raw = parts[2]
                p_cpu_limit_raw = parts[4]
                p_mem_req_raw = parts[6]
                p_mem_limit_raw = parts[8]

                p_cpu_req_formatted = format_cpu_m(p_cpu_req_raw)
                p_cpu_limit_formatted = format_cpu_m(p_cpu_limit_raw)
                p_mem_req_formatted = convert_memory_to_mib(p_mem_req_raw)
                p_mem_limit_formatted = convert_memory_to_mib(p_mem_limit_raw)

                pod_details_data.append([
                    ns_name, p_name, p_cpu_req_formatted, p_cpu_limit_formatted,
                    p_mem_req_formatted, p_mem_limit_formatted
                ])

    mem_req_formatted = convert_memory_to_gib(mem_req_raw)
    mem_limit_formatted = convert_memory_to_gib(mem_limit_raw)
    cpu_req_formatted = format_cpu_cores(cpu_req)
    cpu_limit_formatted = format_cpu_cores(cpu_limit)

    node_summary_data = [
        cpu_req_formatted, cpu_limit_formatted,
        mem_req_formatted, mem_limit_formatted,
        cpu_capacity_formatted, mem_capacity_formatted,
        num_pods
    ]

    return node_summary_data, pod_details_data


def main():
    parser = argparse.ArgumentParser(description="Gather OpenShift workload resource requests/limits, quotas/limit ranges, and node details.")
    parser.add_argument("--workloads", action="store_true", help="Gathers deployment, deploymentconfig, and statefulset resource requests and limits.")
    parser.add_argument("--quotas-limits", action="store_true", help="Gathers resource quota and limit range details for each namespace.")
    parser.add_argument("--nodes", action="store_true", help="Gathers total CPU/memory requests/limits, pod count, and node capacity for each node.")
    parser.add_argument("--debug", action="store_true", help="Prints detailed CSV data to stdout during execution.")

    args = parser.parse_args()

    if not any([args.workloads, args.quotas_limits, args.nodes]):
        parser.print_help()
        exit(1)

    check_prerequisites()

    # Get namespaces
    namespaces_str = run_command("oc get projects -o jsonpath='{.items[*].metadata.name}'", ignore_errors=True)
    NAMESPACES = namespaces_str.split() if namespaces_str else []

    # Get node names
    nodes_str = run_command("oc get nodes -o jsonpath='{.items[*].metadata.name}'", ignore_errors=True)
    NODES = nodes_str.split() if nodes_str else []

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = f"resource-gather_{timestamp}"
    os.makedirs(output_dir, exist_ok=True)

    if args.workloads:
        workload_output_file = os.path.join(output_dir, "workload.csv")
        workload_csv_header = ["Namespace", "WorkloadType", "WorkloadName", "ContainerName", "CpuRequest (m)", "MemoryRequest (Mi)", "CpuLimit (m)", "MemoryLimit (Mi)"]

        print(f"Gathering workload resource requests and limits. Output will be saved to '{workload_output_file}'.")
        print()

        with open(workload_output_file, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(workload_csv_header)
            if args.debug:
                print(','.join(workload_csv_header))

            for ns in NAMESPACES:
                for workload_type in ["deployment", "deploymentconfig", "statefulset"]:
                    workload_names_str = run_command(f"oc get {workload_type} -n {ns} -o jsonpath='{{.items[*].metadata.name}}'", ignore_errors=True)
                    workload_names = workload_names_str.split() if workload_names_str else []

                    for workload_name in workload_names:
                        resource_data = get_workload_resources(ns, workload_type, workload_name)
                        for row in resource_data:
                            writer.writerow(row)
                            if args.debug:
                                print(','.join(row))
        print("\nWorkload data collection complete. Output saved to '{workload_output_file}'.")

    if args.quotas_limits:
        quotas_output_file = os.path.join(output_dir, "quotas-limits.csv")

        # Removed CpuHard, CpuUsed, MemoryHard, MemoryUsed
        quota_csv_header = ["Namespace", "QuotaName", "PodsHard", "PodsUsed",
                            "RequestsCpuHard (cores)", "RequestsCpuUsed (cores)",
                            "RequestsMemoryHard (Gi)", "RequestsMemoryUsed (Gi)",
                            "LimitsCpuHard (cores)", "LimitsCpuUsed (cores)",
                            "LimitsMemoryHard (Gi)", "LimitsMemoryUsed (Gi)",
                            "PvcsHard", "PvcsUsed", "RequestsStorageHard (Gi)",
                            "RequestsStorageUsed (Gi)", "ConfigMapsHard", "ConfigMapsUsed",
                            "SecretsHard", "SecretsUsed", "ServicesHard", "ServicesUsed"]

        limitrange_csv_header = ["Namespace", "LimitRangeName", "ContainerDefaultCpuRequest (m)", "ContainerDefaultMemoryRequest (Mi)",
                                  "ContainerDefaultCpuLimit (m)", "ContainerDefaultMemoryLimit (Mi)", "ContainerMaxCpu (m)", "ContainerMaxMemory (Mi)",
                                  "ContainerMinCpu (m)", "ContainerMinMemory (Mi)", "PodMaxCpu (m)", "PodMaxMemory (Mi)",
                                  "PodMinCpu (m)", "PodMinMemory (Mi)", "PodDefaultCpuRequest (m)", "PodDefaultMemoryRequest (Mi)",
                                  "PodDefaultCpuLimit (m)", "PodDefaultMemoryLimit (Mi)", "PvcDefaultStorage (Mi)", "PvcMaxStorage (Mi)"]

        print(f"Gathering resource quota and limit range details. Output will be saved to '{quotas_output_file}'.")
        print()

        with open(quotas_output_file, 'w', newline='') as f:
            writer = csv.writer(f)

            writer.writerow(["# --- Resource Quotas ---"])
            writer.writerow(quota_csv_header)
            if args.debug:
                print("--- Resource Quotas ---")
                print(','.join(quota_csv_header))

            for ns in NAMESPACES:
                resource_quotas_str = run_command(f"oc get resourcequotas -n {ns} -o jsonpath='{{.items[*].metadata.name}}'", ignore_errors=True)
                resource_quotas = resource_quotas_str.split() if resource_quotas_str else []

                for rq in resource_quotas:
                    quota_data = get_resource_quota_details(ns, rq)
                    if quota_data:
                        writer.writerow(quota_data)
                        if args.debug:
                            print(','.join(quota_data))

            writer.writerow(["# --- Limit Ranges ---"])
            writer.writerow(limitrange_csv_header)
            if args.debug:
                print("\n--- Limit Ranges ---")
                print(','.join(limitrange_csv_header))

            for ns in NAMESPACES:
                limit_ranges_str = run_command(f"oc get limitranges -n {ns} -o jsonpath='{{.items[*].metadata.name}}'", ignore_errors=True)
                limit_ranges = limit_ranges_str.split() if limit_ranges_str else []

                for lr in limit_ranges:
                    limit_data = get_limit_range_details(ns, lr)
                    if limit_data:
                        writer.writerow(limit_data)
                        if args.debug:
                            print(','.join(limit_data))
        print(f"\nQuotas and Limit Ranges data collection complete. Output saved to '{quotas_output_file}'.")

    if args.nodes:
        nodes_output_file = os.path.join(output_dir, "nodes.csv")
        node_summary_csv_header = ["CpuRequest (cores)", "CpuLimit (cores)", "MemoryRequest (Gi)", "MemoryLimit (Gi)", "CpuCapacity (cores)", "MemoryCapacity (Gi)", "PodsCount"]
        pod_details_csv_header = ["Namespace", "PodName", "CpuRequest (m)", "CpuLimit (m)", "MemRequest (Mi)", "MemLimit (Mi)"]

        print(f"Gathering node resource requests, limits, and pod counts. Output will be saved to '{nodes_output_file}'.")
        print()

        with open(nodes_output_file, 'w', newline='') as f:
            writer = csv.writer(f)
            if args.debug:
                print("--- Node Details ---")

            for node in NODES:
                node_summary_data, pod_details_data = get_node_details(node)
                if node_summary_data is not None:
                    writer.writerow([f"# --- {node} ---"])
                    writer.writerow(node_summary_csv_header)
                    writer.writerow(node_summary_data)
                    writer.writerow(["# --- Pods ---"])
                    writer.writerow(pod_details_csv_header)
                    writer.writerows(pod_details_data)
                    
                    # Add 3 empty rows after each node's block
                    writer.writerow([])
                    writer.writerow([])
                    writer.writerow([])

                    if args.debug:
                        print(f"# --- {node} ---")
                        print(','.join(node_summary_csv_header))
                        print(','.join(node_summary_data))
                        print("# --- Pods ---")
                        print(','.join(pod_details_csv_header))
                        for pod_row in pod_details_data:
                            print(','.join(pod_row))
                        print("\n\n") # 3 newlines for readability in debug

        print(f"\nNode data collection complete. Output saved to '{nodes_output_file}'.")
    
    print("\nScript execution finished.")

if __name__ == "__main__":
    main()