#!/usr/bin/env bash
# gcp_audit — API-aware sweep for lingering/billable-ish GCP resources (summary-first)
#
# Author: Steve Foris (https://github.com/steve-foris)
# Date: 2025-12

# usage:
#   gcp_audit.sh [--project <id|ALL>] [--region <name>] [--zone <name>]
#                [--timeout <sec>] [--billable-only] [--details] [--summary-only] [--json]
#
# defaults:
# - summary-first: prints details ONLY when count>0 (or when --details is set)
# - --summary-only: prints ONLY the final summary (still collects counts)
# - never prompts, never enables APIs, never mutates resources
#
# Requires: gcloud
# Optional: bq (BigQuery)

#TODO:
# - Treat _Default / _Required logging sinks as “baseline”
#   Could later mark them as logging_sinks(system)

# - Add --fail-if-billable
#   Exit non-zero if summary not empty → CI gate after terraform destroy

# - Add --summary-only --json
#   For piping into dashboards / reports

# - Add BQ billing 
#   Optional --with-costs (BigQuery billing export)
#   Warn if billing export not enabled
#   Show month-to-date only (keep it cheap + fast)
#   Never block audit if billing unavailable


set -euo pipefail
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || true)}"
ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || true)}"
DO_ALL=false
OUT_JSON=false
TIMEOUT_SEC=20
BILLABLE_ONLY=false
DETAILS=false
SUMMARY_ONLY=true

usage() {
  cat <<'EOF'
gcp_audit.sh — API-aware GCP billable resource audit (summary-first)

USAGE:
  gcp_audit.sh [OPTIONS]

OPTIONS:
  --project <id>        Audit a single project
  --project ALL         Audit all accessible projects
  --region <name>       Optional region hint (informational)
  --zone <name>         Optional zone hint (informational)

  --summary-only        Show only the final summary (disable details)
  --billable-only       Show only billable / cost-adjacent resources
  --details             Always show detailed output (disable summary-first)
  --json                Output resource listings as JSON
  --timeout <sec>       Per-command timeout (default: 20s)

  -h, --help            Show this help and exit

BEHAVIOUR:
  - Never enables APIs
  - Never mutates resources
  - Skips services whose APIs are disabled
  - Always prints a summary of billable-ish findings

EXAMPLES:
  gcp_audit.sh
  gcp_audit.sh --project tf-migtest-demo --billable-only
  gcp_audit.sh --project ALL --timeout 10 --summary-only
  gcp_audit.sh --details

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    # Use project from gcloud config if not specified or do ALL if empty.
    --project)
      if [[ "${2:-}" == "ALL" ]]; then
        DO_ALL=true; PROJECT=""; shift 2
      else
        PROJECT="${2:-}"; shift 2
      fi
      ;;
    --region) REGION="${2:-}"; shift 2;;
    --zone)   ZONE="${2:-}"; shift 2;;
    --timeout) TIMEOUT_SEC="${2:-20}"; shift 2;;
    --billable-only) BILLABLE_ONLY=true; shift;;
    --summary-only) SUMMARY_ONLY=true; shift;;
    --details) DETAILS=true;SUMMARY_ONLY=false; shift;;
    --json) OUT_JSON=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# Helper functions
have_cmd() { command -v "$1" >/dev/null 2>&1; }
hr() { echo "------------------------------------------------------------"; }

# Section header
section() {
  $SUMMARY_ONLY && return 0
  echo
  hr
  echo "## $*"
  hr
}

# Timeout wrapper
tmo() {
  if have_cmd timeout; then
    timeout "${TIMEOUT_SEC}" "$@"
  else
    "$@"
  fi
}

# Enabled APIs cache per project
declare -A ENABLED_APIS_CACHE
load_enabled_apis() {
  local project="$1"
  [[ -n "${ENABLED_APIS_CACHE[$project]:-}" ]] && return 0
  ENABLED_APIS_CACHE["$project"]="$(tmo gcloud services list --enabled --project="$project" --quiet --format='value(config.name)' 2>/dev/null || true)"
}
api_enabled() {
  local project="$1" api="$2"
  load_enabled_apis "$project"
  local apis="${ENABLED_APIS_CACHE[$project]}"
  [[ -n "$apis" ]] && grep -qxF "$api" <<<"$apis"
}

# Summary accumulators
declare -A SUM_COUNTS   # "project|category" => count
declare -A SUM_ANY      # "project" => 1
sum_set() {
  local project="$1" category="$2" count="$3"
  SUM_COUNTS["$project|$category"]="$count"
  if (( count > 0 )); then
    SUM_ANY["$project"]=1
  fi
}

# Print detail output only if:
# - --details specified, OR
# - count > 0 (summary-first)
should_print_details() {
  local count="$1"
  $DETAILS && return 0
  (( count > 0 ))
}

# Generic gcloud resource lister; records count; prints details conditionally.
# Args: project title category cmd...
run_gcloud() {
  local project="$1"; shift
  local title="$1"; shift
  local category="$1"; shift
  local -a cmd=( "$@" )

  local names=""
  names="$(tmo "${cmd[@]}" --project="$project" --quiet --format='value(name)' 2>/dev/null || true)"
  local count=0
  [[ -n "${names//$'\n'/}" ]] && count="$(wc -l <<<"$names" | tr -d ' ')"

  sum_set "$project" "$category" "$count"

  if ! $SUMMARY_ONLY && should_print_details "$count"; then
    echo "---- ${title} (count=${count}) ----"
    if (( count > 0 )); then
      if $OUT_JSON; then
        tmo "${cmd[@]}" --project="$project" --quiet --format=json 2>/dev/null || true
      else
        if printf '%s\0' "${cmd[@]}" | grep -qz -- '--format'; then
          tmo "${cmd[@]}" --project="$project" --quiet 2>/dev/null || true
        else
          tmo "${cmd[@]}" --project="$project" --quiet --format='table(name)' 2>/dev/null || true
        fi
      fi
    fi
    echo
  fi
}

# Special: GCS buckets
run_gcs_buckets() {
  local project="$1" title="$2" category="$3"

  if ! api_enabled "$project" "storage.googleapis.com"; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (SKIP: storage.googleapis.com not enabled) ----"
      echo
    fi
    return 0
  fi

  local names=""
  names="$(tmo gcloud storage buckets list --project="$project" --quiet --format='value(name)' 2>/dev/null || true)"
  local count=0
  [[ -n "${names//$'\n'/}" ]] && count="$(wc -l <<<"$names" | tr -d ' ')"

  sum_set "$project" "$category" "$count"

  if ! $SUMMARY_ONLY && should_print_details "$count"; then
    echo "---- ${title} (count=${count}) ----"
    if (( count > 0 )); then
      if $OUT_JSON; then
        tmo gcloud storage buckets list --project="$project" --quiet --format=json 2>/dev/null || true
      else
        tmo gcloud storage buckets list --project="$project" --quiet \
          --format='table(name,location,storageClass,uniformBucketLevelAccess.enabled:label=UBLA,publicAccessPrevention:label=PAP)' \
          2>/dev/null || true
      fi
    fi
    echo
  fi
}

# Special: Cloud Run services
run_cloud_run() {
  local project="$1" title="$2" category="$3"

  if ! api_enabled "$project" "run.googleapis.com"; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (SKIP: run.googleapis.com not enabled) ----"
      echo
    fi
    return 0
  fi

  local names=""
  names="$(tmo gcloud run services list --project="$project" --platform=managed --quiet --format='value(name)' 2>/dev/null || true)"
  local count=0
  [[ -n "${names//$'\n'/}" ]] && count="$(wc -l <<<"$names" | tr -d ' ')"

  sum_set "$project" "$category" "$count"

  if ! $SUMMARY_ONLY && should_print_details "$count"; then
    echo "---- ${title} (count=${count}) ----"
    if (( count > 0 )); then
      if $OUT_JSON; then
        tmo gcloud run services list --project="$project" --platform=managed --quiet --format=json 2>/dev/null || true
      else
        tmo gcloud run services list --project="$project" --platform=managed --quiet \
          --format='table(name,region,ingress,status,url)' 2>/dev/null || true
      fi
    fi
    echo
  fi
}

# Special: Artifact Registry repos (per-location enumeration)
run_artifacts() {
  local project="$1" title="$2" category="$3"

  if ! api_enabled "$project" "artifactregistry.googleapis.com"; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (SKIP: artifactregistry.googleapis.com not enabled) ----"
      echo
    fi
    return 0
  fi

  local locs=""
  locs="$(tmo gcloud artifacts locations list --project="$project" --quiet --format='value(locationId)' 2>/dev/null || true)"
  if [[ -z "${locs//$'\n'/}" ]]; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (count=0) ----"
      echo
    fi
    return 0
  fi

  local total=0
  while read -r loc; do
    [[ -z "$loc" ]] && continue
    local names=""
    names="$(tmo gcloud artifacts repositories list --project="$project" --location="$loc" --quiet --format='value(name)' 2>/dev/null || true)"
    if [[ -n "${names//$'\n'/}" ]]; then
      local c
      c="$(wc -l <<<"$names" | tr -d ' ')"
      total=$((total + c))
    fi
  done <<<"$locs"

  sum_set "$project" "$category" "$total"

  if ! $SUMMARY_ONLY && should_print_details "$total"; then
    echo "---- ${title} (total=${total}) ----"
    if (( total > 0 )); then
      while read -r loc; do
        [[ -z "$loc" ]] && continue
        local names=""
        names="$(tmo gcloud artifacts repositories list --project="$project" --location="$loc" --quiet --format='value(name)' 2>/dev/null || true)"
        if [[ -n "${names//$'\n'/}" ]]; then
          local c
          c="$(wc -l <<<"$names" | tr -d ' ')"
          echo "  location ${loc}: ${c}"
          if $OUT_JSON; then
            tmo gcloud artifacts repositories list --project="$project" --location="$loc" --quiet --format=json 2>/dev/null || true
          else
            tmo gcloud artifacts repositories list --project="$project" --location="$loc" --quiet \
              --format='table(name,format,location,createTime)' 2>/dev/null || true
          fi
          echo
        fi
      done <<<"$locs"
    fi
    echo
  fi
}

# BigQuery datasets (count is approximate: any output => 1)
run_bigquery() {
  local project="$1" title="$2" category="$3"

  if ! api_enabled "$project" "bigquery.googleapis.com"; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (SKIP: bigquery.googleapis.com not enabled) ----"
      echo
    fi
    return 0
  fi
  if ! have_cmd bq; then
    sum_set "$project" "$category" 0
    if ! $SUMMARY_ONLY && $DETAILS; then
      echo "---- ${title} (SKIP: bq CLI not installed) ----"
      echo
    fi
    return 0
  fi

  local out=""
  out="$(tmo bq --project_id="$project" ls 2>/dev/null || true)"
  local count=0
  [[ -n "${out//$'\n'/}" ]] && count=1
  sum_set "$project" "$category" "$count"

  if ! $SUMMARY_ONLY && should_print_details "$count"; then
    echo "---- ${title} ----"
    [[ -n "${out//$'\n'/}" ]] && echo "$out"
    echo
  fi
}

audit_one_project() {
  local project="$1"

  load_enabled_apis "$project"

  if ! $SUMMARY_ONLY; then
    echo
    echo "== GCP audit for project: ${project} =="
    [[ -n "${REGION}" ]] && echo "   region: ${REGION}"
    [[ -n "${ZONE}"   ]] && echo "   zone:   ${ZONE}"
    $BILLABLE_ONLY && echo "   mode:    billable-only"
    $DETAILS && echo "   details: true"
    echo "   timeout: ${TIMEOUT_SEC}s"
    echo
  fi

  section "Storage"
  run_gcs_buckets "$project" "Cloud Storage buckets (GCS — billable storage)" "gcs_buckets"
  run_gcloud "$project" "Snapshots (billable)" "snapshots" \
    gcloud compute snapshots list --format='table(name,sourceDisk,storageBytes:label=bytes,creationTimestamp)'
  run_gcloud "$project" "Custom images (billable)" "custom_images" \
    gcloud compute images list --no-standard-images --format='table(name,family,diskSizeGb,storageLocations,status)'
  run_gcloud "$project" "Unattached disks (billable)" "unattached_disks" \
    gcloud compute disks list --filter='-users:*' --format='table(name,zone,sizeGb,type,status)'

  section "Compute"
  run_gcloud "$project" "Instances (RUNNING — CPU $$)" "running_instances" \
    gcloud compute instances list --filter='status=RUNNING' \
    --format='table(name,zone,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)'
  run_gcloud "$project" "Managed Instance Groups" "migs" \
    gcloud compute instance-groups managed list --format='table(name,location,scope,baseInstanceName,targetSize,autoscaled)'

  section "Load balancing & networking"
  run_gcloud "$project" "Global static IPs (RESERVED = billable)" "global_ips" \
    gcloud compute addresses list --global \
    --format='table(name,address,status,networkTier,users.list():label=users)'
  run_gcloud "$project" "Regional static IPs" "regional_ips" \
    gcloud compute addresses list \
    --format='table(name,address,region,status,networkTier,users.list():label=users)'
  run_gcloud "$project" "Global forwarding rules (billable-ish even idle)" "global_fwd" \
    gcloud compute forwarding-rules list --global \
    --format='table(name,IPAddress,IPProtocol,portRange,target,loadBalancingScheme)'
  run_gcloud "$project" "Regional forwarding rules" "regional_fwd" \
    gcloud compute forwarding-rules list \
    --format='table(name,region,IPAddress,IPProtocol,portRange,target,loadBalancingScheme)'
  run_gcloud "$project" "Backend services (global)" "backend_services_global" \
    gcloud compute backend-services list --global \
    --format='table(name,protocol,portName,loadBalancingScheme,backends.size():label=backends,healthChecks.size():label=hc)'
  run_gcloud "$project" "Backend services (regional)" "backend_services_regional" \
    gcloud compute backend-services list \
    --format='table(name,region,protocol,portName,loadBalancingScheme,backends.size():label=backends,healthChecks.size():label=hc)'
  run_gcloud "$project" "SSL certificates" "ssl_certs" \
    gcloud compute ssl-certificates list
  run_gcloud "$project" "Network endpoint groups (NEGs)" "negs" \
    gcloud compute network-endpoint-groups list \
    --format='table(name,zone,networkEndpointType,size,defaultPort,network.basename(),subnetwork.basename())'

  if ! $BILLABLE_ONLY; then
    section "Informational (non-billable, unless you do something impressive)"
    run_gcloud "$project" "Compute backend buckets (LB feature, NOT GCS)" "info_backend_buckets" \
      gcloud compute backend-buckets list
    run_gcloud "$project" "Target HTTP proxies" "info" gcloud compute target-http-proxies list
    run_gcloud "$project" "Target HTTPS proxies" "info" gcloud compute target-https-proxies list
    run_gcloud "$project" "URL maps" "info" gcloud compute url-maps list
    run_gcloud "$project" "Health checks (global)" "info" gcloud compute health-checks list
    run_gcloud "$project" "Routers" "info" gcloud compute routers list --format='table(name,region,network.basename())'
    run_gcloud "$project" "Firewall rules (info)" "info" \
      gcloud compute firewall-rules list --format='table(name,network,direction,priority,allowed,denied,disabled)'
  fi

  section "Managed services"
  if api_enabled "$project" "sqladmin.googleapis.com"; then
    run_gcloud "$project" "Cloud SQL instances (billable)" "cloudsql" \
      gcloud sql instances list --format='table(name,databaseVersion,region,tier,state,ipAddresses[0].ipAddress:label=ip)'
  else
    sum_set "$project" "cloudsql" 0
  fi

  if api_enabled "$project" "container.googleapis.com"; then
    run_gcloud "$project" "GKE clusters (billable control plane + nodes)" "gke" \
      gcloud container clusters list --format='table(name,location,status,currentMasterVersion,currentNodeVersion,nodePools.size():label=pools)'
  else
    sum_set "$project" "gke" 0
  fi

  run_cloud_run "$project" "Cloud Run services" "cloudrun"
  run_artifacts "$project" "Artifact Registry repositories" "artifacts"

  if api_enabled "$project" "pubsub.googleapis.com"; then
    run_gcloud "$project" "Pub/Sub topics" "pubsub" \
      gcloud pubsub topics list --format='table(name)'
  else
    sum_set "$project" "pubsub" 0
  fi

  if api_enabled "$project" "logging.googleapis.com"; then
    run_gcloud "$project" "Logging sinks (exports can cost money)" "logging_sinks" \
      gcloud logging sinks list --format='table(name,destination,filter)'
  else
    sum_set "$project" "logging_sinks" 0
  fi

  run_bigquery "$project" "BigQuery datasets" "bigquery"

  if ! $SUMMARY_ONLY; then
    echo "== audit complete for ${project} =="
  fi
}

print_summary() {
  echo
  hr
  echo "## Summary (projects with billable-ish resources found)"
  hr

  local any=false
  for project in "${!SUM_ANY[@]}"; do
    any=true
    echo "- ${project}"
    for cat in \
      gcs_buckets snapshots custom_images unattached_disks running_instances migs \
      global_ips regional_ips global_fwd regional_fwd backend_services_global backend_services_regional ssl_certs negs \
      cloudsql gke cloudrun artifacts pubsub logging_sinks bigquery; do
      local val="${SUM_COUNTS[$project|$cat]:-0}"
      (( val > 0 )) && echo "    - ${cat}: ${val}"
    done
  done

  $any || echo "(no billable-ish resources detected by this tool)"
  echo
}

audit_all_projects() {
  mapfile -t ALL_PROJECTS < <(gcloud projects list --quiet --format='value(projectId)' 2>/dev/null || true)
  if [[ ${#ALL_PROJECTS[@]} -eq 0 ]]; then
    echo "No projects found. Use --project <id> or configure a project." >&2
    exit 1
  fi
  for pid in "${ALL_PROJECTS[@]}"; do
    audit_one_project "$pid"
  done
}

# Decide scope once, then always print summary.
if $DO_ALL || [[ -z "${PROJECT}" ]]; then
  audit_all_projects
else
  audit_one_project "${PROJECT}"
fi

print_summary
