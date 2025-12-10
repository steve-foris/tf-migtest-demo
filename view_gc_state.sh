#!/bin/bash

# Handy view status of GCE instances and load balancer
REFRESH_RATE=30
CURL_TIMEOUT=2

clear
while true; do
    # Build output in memory first
    out=""
    out+=$(date)$'\n'
    out+="=== Instance Responses ==="$'\n'
    for ip in $(gcloud compute instances list --format="value(EXTERNAL_IP)"); do
        resp=$(curl -s --max-time "$CURL_TIMEOUT" --connect-timeout "$CURL_TIMEOUT" "http://$ip" || echo "[timeout]")
        out+="$ip: $resp"$'\n'
    done

    out+=$'\n'"=== Instance List ==="$'\n'
    out+="$(gcloud compute instances list)"$'\n'

    out+=$'\n'"=== Instance groups ==="$'\n'
    out+="$(gcloud compute instance-groups managed list)"$'\n'

    out+=$'\n'"=== Load Balancer Response ==="$'\n'
    LB_IP=$(terraform output -raw lb_ip)
    lb_resp=$(curl -s --max-time "$CURL_TIMEOUT" --connect-timeout "$CURL_TIMEOUT" "http://$LB_IP" || echo "[LB timeout]")
    out+="$LB_IP: $lb_resp"$'\n'

    clear
    printf "%s" "$out"

    sleep "$REFRESH_RATE"
done
