#!/bin/bash

# Default Configuration
DEPLOYMENT_FILE="vllm-deployment.yaml"
DEPLOYMENT_NAME="vllm-deployment"
CONTAINER_NAME="inference-server"
APP_LABEL="model-server"

# Function to delete nodes to force scale-up
delete_gpu_nodes() {
    echo "Cleaning up GPU nodes to ensure scale-up event..."
    NODES=$(kubectl get nodes -l cloud.google.com/compute-class=l4 -o name)
    if [ ! -z "$NODES" ]; then
        for NODE in $NODES; do
            echo "Deleting $NODE..."
            kubectl delete $NODE --wait=false > /dev/null 2>&1
        done
        echo "Waiting for nodes to be removed from cluster..."
        while true; do
            STILL_THERE=$(kubectl get nodes -l cloud.google.com/compute-class=l4 -o name)
            if [ -z "$STILL_THERE" ]; then break; fi
            printf "."
            sleep 5
        done
        echo -e "\nGPU nodes removed."
    else
        echo "No existing GPU nodes found."
    fi
}

run_measurement() {
    local MODE=$1
    local D_FILE=$2
    local A_LABEL=$3
    local C_NAME=$4

    echo -e "\n>>> Starting Measurement for Mode: $MODE"

    # Ensure clean start
    echo "Step 1: Deleting existing deployment for a true cold-start measure..."
    kubectl delete -f $D_FILE --ignore-not-found=true > /dev/null
    echo "Waiting for pods to terminate..."
    kubectl wait --for=delete pod -l app=$A_LABEL --timeout=120s > /dev/null 2>&1

    # Force node deletion if requested or as part of cold start
    delete_gpu_nodes

    echo "Step 2: Applying deployment..."
    APPLY_TIME=$(date +%s)
    kubectl apply -f $D_FILE > /dev/null

    echo "Step 3: Monitoring Kubernetes Events (Provisioning/Pulling)..."
    while true; do
        POD_NAME=$(kubectl get pods -l app=$A_LABEL --sort-by=.metadata.creationTimestamp | grep -v "Terminating" | tail -n 1 | awk '{print $1}')
        if [ ! -z "$POD_NAME" ]; then
            # Check if node is assigned
            NODE_NAME=$(kubectl get pod $POD_NAME -o jsonpath='{.spec.nodeName}' 2>/dev/null)
            if [ ! -z "$NODE_NAME" ]; then
                break
            fi
        fi
        printf "."
        sleep 2
    done
    echo -e "\nPod $POD_NAME scheduled on node $NODE_NAME."

    # Wait for container to start (pulling happens here)
    echo "Waiting for image pull and container start..."
    while true; do
        STARTED_AT=$(kubectl get pod $POD_NAME -o jsonpath='{.status.containerStatuses[?(@.name=="'$C_NAME'")].state.running.startedAt}' 2>/dev/null)
        if [ ! -z "$STARTED_AT" ]; then
            break
        fi
        sleep 2
    done

    # Wait for vLLM App to be ready
    echo "Waiting for vLLM Application to be Ready (this can take 5-10 minutes)..."
    while true; do
        LOGS=$(kubectl logs $POD_NAME -c $C_NAME 2>/dev/null)
        if echo "$LOGS" | grep -q "Application startup complete"; then
            READY_TIME=$(date +%s)
            break
        fi
        # Check if pod is failing
        STATUS=$(kubectl get pod $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$STATUS" == "Failed" ]; then
            echo "Pod failed to start."
            return 1
        fi
        printf "."
        sleep 10
    done
    echo ""

    # Get cluster timestamps for the breakdown
    POD_JSON=$(kubectl get pod $POD_NAME -o json)
    CREATION_TIME=$(date -d "$(echo "$POD_JSON" | jq -r '.metadata.creationTimestamp')" +%s)
    SCHEDULE_TIME=$(date -d "$(echo "$POD_JSON" | jq -r '.status.conditions[] | select(.type=="PodScheduled") | .lastTransitionTime' | head -n 1)" +%s)
    CONTAINER_START_TIME=$(date -d "$(echo "$POD_JSON" | jq -r '.status.containerStatuses[] | select(.name=="'$C_NAME'") | .state.running.startedAt')" +%s)

    # Extract Image Pull Time from Events
    PULL_START=$(kubectl get events --field-selector involvedObject.name=$POD_NAME -o json | jq -r '.items[] | select(.reason=="Pulling") | .firstTimestamp' | head -n 1)
    PULL_END=$(kubectl get events --field-selector involvedObject.name=$POD_NAME -o json | jq -r '.items[] | select(.reason=="Pulled") | .firstTimestamp' | head -n 1)

    if [ ! -z "$PULL_START" ] && [ ! -z "$PULL_END" ]; then
        P_START_SEC=$(date -d "$PULL_START" +%s)
        P_END_SEC=$(date -d "$PULL_END" +%s)
        PULL_DURATION=$((P_END_SEC - P_START_SEC))
    else
        PULL_DURATION=0 
    fi

    NODE_PROV=$((SCHEDULE_TIME - CREATION_TIME))
    PULL_TIME=$PULL_DURATION
    RUNTIME_START=$((CONTAINER_START_TIME - SCHEDULE_TIME - PULL_DURATION))
    TOTAL_WALL=$((READY_TIME - APPLY_TIME))

    # Parse logs for internal breakdown
    LOAD_TIME=$(echo "$LOGS" | grep "Loading weights took" | sed -E 's/.*took ([0-9.]+) seconds.*/\1/' | head -n 1)
    COMPILE_TIME=$(echo "$LOGS" | grep "torch.compile takes" | sed -E 's/.*takes ([0-9.]+) s.*/\1/' | head -n 1)
    GRAPH_TIME=$(echo "$LOGS" | grep "Graph capturing finished" | sed -E 's/.*finished in ([0-9.]+) secs.*/\1/' | head -n 1)

    # Store results in variables for comparison
    if [[ "$MODE" == "Standard" ]]; then
        S_NODE_PROV=$NODE_PROV; S_PULL=$PULL_TIME; S_RUNTIME=$RUNTIME_START; S_TOTAL=$TOTAL_WALL
        S_LOAD=${LOAD_TIME:-0}; S_COMPILE=${COMPILE_TIME:-0}; S_GRAPH=${GRAPH_TIME:-0}
    else
        R_NODE_PROV=$NODE_PROV; R_PULL=$PULL_TIME; R_RUNTIME=$RUNTIME_START; R_TOTAL=$TOTAL_WALL
        R_LOAD=${LOAD_TIME:-0}; R_COMPILE=${COMPILE_TIME:-0}; R_GRAPH=${GRAPH_TIME:-0}
    fi

    echo "------------------------------------------------"
    echo "Metrics for $MODE ($POD_NAME)"
    echo "------------------------------------------------"
    echo "1. Node Provisioning:    ${NODE_PROV}s"
    echo "2. Image Pulling:        ${PULL_TIME}s"
    echo "3. Runtime Startup:      ${RUNTIME_START}s"
    echo "------------------------------------------------"
    echo "Total Wall Clock:        ${TOTAL_WALL}s"
    echo "------------------------------------------------"
}

# Handle arguments
if [[ "$1" == "--compare" ]]; then
    echo "Entering Comparison Mode: Standard vs AI Model Streamer"
    
    # Run Standard
    run_measurement "Standard" "vllm-deployment.yaml" "model-server" "inference-server"
    
    # Run RunAI
    run_measurement "RunAI" "vllm-deployment-runai.yaml" "model-server-runai" "vllm-container"
    
    echo -e "\n========================================================"
    echo "           STARTUP PERFORMANCE COMPARISON"
    echo "========================================================"
    printf "%-25s | %-12s | %-12s\n" "Metric" "Standard" "RunAI"
    echo "--------------------------------------------------------"
    printf "%-25s | %-10ss | %-10ss\n" "Node Provisioning" "$S_NODE_PROV" "$R_NODE_PROV"
    printf "%-25s | %-10ss | %-10ss\n" "Image Pulling" "$S_PULL" "$R_PULL"
    printf "%-25s | %-10ss | %-10ss\n" "Runtime Startup" "$S_RUNTIME" "$R_RUNTIME"
    printf "%-25s | %-10ss | %-10ss\n" "vLLM Weight Loading" "$S_LOAD" "$R_LOAD"
    printf "%-25s | %-10ss | %-10ss\n" "Torch Compilation" "$S_COMPILE" "$R_COMPILE"
    printf "%-25s | %-10ss | %-10ss\n" "CUDA Graph Capture" "$S_GRAPH" "$R_GRAPH"
    echo "--------------------------------------------------------"
    printf "%-25s | %-10ss | %-10ss\n" "TOTAL WALL CLOCK" "$S_TOTAL" "$R_TOTAL"
    echo "========================================================"
    
    # Calculate improvement
    DIFF=$((S_TOTAL - R_TOTAL))
    if [ $DIFF -gt 0 ]; then
        echo "RunAI is ${DIFF}s faster than Standard."
    else
        echo "Standard is $(( -DIFF ))s faster than RunAI."
    fi

elif [[ "$1" == "--runai" ]]; then
    echo "Mode: AI Model Streamer (models.gke.io)"
    run_measurement "RunAI" "vllm-deployment-runai.yaml" "model-server-runai" "vllm-container"
else
    echo "Mode: Standard (GCS Fuse Sidecar)"
    run_measurement "Standard" "vllm-deployment.yaml" "model-server" "inference-server"
fi
