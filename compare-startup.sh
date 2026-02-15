#!/bin/bash
# Compare startup times: Standard vs Image Streaming

APP_STANDARD="large-image-standard"
APP_STREAMING="large-image-streaming"

# Function to reset node cache
reset_cache() {
    echo "--- Resetting Node Cache ---"
    echo "Deploying image-cleaner DaemonSet..."
    kubectl apply -f reset-cache.yaml >/dev/null

    echo "Waiting for cleaner to run..."
    kubectl wait --for=condition=Ready pod -l app=image-cleaner --timeout=60s >/dev/null

    echo "Cache cleared. Deleting cleaner..."
    kubectl delete -f reset-cache.yaml >/dev/null
    echo "Done."
    echo ""
}

# Function to measure startup time
measure_startup() {
    local app_label=$1
    local file=$2
    local name=$3

    echo "--- Testing $name ---"
    # Clean up previous runs
    echo "Cleaning up previous $app_label..."
    kubectl delete deployment -l app=$app_label --ignore-not-found=true --wait=true >/dev/null 2>&1
    
    # Ensure pod is gone (double check)
    kubectl wait --for=delete pod -l app=$app_label --timeout=60s >/dev/null 2>&1 || true

    echo "Deploying..."
    echo "Deploying..."
    start_time=$(date +%s)
    kubectl apply -f $file
    
    # Wait for Pod to be schedulable first, then Ready
    kubectl wait --for=condition=Ready pod -l app=$app_label --timeout=600s >/dev/null
    end_time=$(date +%s)
    
    duration=$((end_time - start_time))
    echo "$name Ready Time: ${duration} seconds"

    # Verify Image Streaming events if expected
    if [ "$name" == "Image Streaming" ]; then
        echo "Verifying Image Streaming usage..."
        # Get the pod name
        POD_NAME=$(kubectl get pod -l app=$app_label -o jsonpath='{.items[0].metadata.name}')
        # Check for ImageStreaming events (might be on the Node)
        # We grep specifically for the success message
        if kubectl get events --sort-by='.lastTimestamp' | grep -i "ImageStreaming" | grep -q "backed by image streaming"; then
             echo "✅ Confirmed: Image Streaming active (Event found)"
             kubectl get events --sort-by='.lastTimestamp' | grep -i "ImageStreaming" | grep "backed by image streaming" | tail -n 1
        else
             echo "⚠️  Warning: No explicit Image Streaming event found yet (might be fast or on Node object)"
        fi
    fi
    echo ""
    return $duration
}

echo "Starting Comparison..."
echo "(Ensure you have created the node pools with ./setup-pools.sh first)"

# Pre-cleanup to ensure images can be deleted
echo "--- PRE-CLEANUP ---"
kubectl delete deployment -l app=$APP_STANDARD --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl delete deployment -l app=$APP_STREAMING --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl wait --for=delete pod -l app=$APP_STANDARD --timeout=60s >/dev/null 2>&1 || true
kubectl wait --for=delete pod -l app=$APP_STREAMING --timeout=60s >/dev/null 2>&1 || true
echo "Cleanup complete."
echo ""

reset_cache

measure_startup $APP_STANDARD "pod-standard.yaml" "Standard Pull"
std_duration=$?

measure_startup $APP_STREAMING "pod-streaming.yaml" "Image Streaming"
str_duration=$?

echo "============================================"
echo "Results:"
echo "Standard Pull:   ${std_duration}s"
echo "Image Streaming: ${str_duration}s"
echo "============================================"
