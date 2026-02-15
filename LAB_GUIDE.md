# Lab Guide: Model Inference Optimization on GKE

This guide outlines the technical steps for deploying and optimizing machine learning model inference on Google Kubernetes Engine (GKE) using Image Streaming, Secondary Boot Disks, and GCS Fuse with **Workload Identity**.

## Feature Overview

*   **Workload Identity**: The recommended way for GKE workloads to access Google Cloud services. It eliminates the need to manage Kubernetes secrets for IAM service account keys and follows the principle of least privilege.
*   **Image Streaming**: Allows GKE to start pods without waiting for the entire container image to be downloaded. It pulls data segments on-demand, reducing startup times for large AI images (e.g., vLLM) from minutes to seconds.
*   **Secondary Boot Disks**: Pre-loads container images onto a separate disk that is attached to nodes during boot. This provides "instant-on" capabilities for new nodes by completely bypassing the network pull process.
*   **GCS Fuse CSI Driver**: Allows you to mount Cloud Storage buckets as local file systems. For ML, this means you can stream massive model weights (TB-scale) directly into your inference engine without pre-downloading them to the node's local disk.
*   **Custom Compute Class**: A GKE automation feature that allows you to define specific hardware requirements (GPUs, machine types) and optimization settings (like Secondary Boot Disks) that GKE uses to automatically provision the right nodes when your pods are deployed.

---

## Task 0: Setup Environment Variables

```bash
export PROJECT_ID=$(gcloud config get-value project)
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="inference-cluster"
export GSA_NAME="vllm-gsa"
export KSA_NAME="vllm-sa"
export SOURCE_BUCKET="gemma3-12b-amirma-private2"
export BUCKET_NAME="gemma3-12b-${PROJECT_ID}"
export IMAGE_NAME="vllm-disk-image-sec"

gcloud config set project $PROJECT_ID
```

---

## Task 1: Enable APIs and Prepare Model Bucket
Because this is a new environment, we need to enable services and prepare your own storage bucket by copying the model weights from the source.

```bash
# Enable APIs
gcloud services enable compute.googleapis.com container.googleapis.com storage.googleapis.com

# Create the Model Bucket
gcloud storage buckets create gs://$BUCKET_NAME --location=$REGION

# Copy the model weights (this ensures you are working with your own copy)
gcloud storage cp -r gs://$SOURCE_BUCKET/* gs://$BUCKET_NAME/

# Create bucket for logs (used by disk image builder)
gcloud storage buckets create gs://$BUCKET_NAME-logs --location=$REGION
```

---

## Task 2: Create a GKE Standard Cluster
Create a GKE cluster with **GCS Fuse CSI driver** and **Workload Identity** enabled. We also enable **Image Streaming** and **Node Auto-provisioning**.

```bash
gcloud container clusters create $CLUSTER_NAME \
  --addons GcsFuseCsiDriver \
  --zone $ZONE \
  --image-type "COS_CONTAINERD" \
  --workload-pool "${PROJECT_ID}.svc.id.goog" \
  --enable-image-streaming \
  --enable-autoprovisioning \
  --min-cpu 1 --max-cpu 1000 \
  --min-memory 1 --max-memory 1000 \
  --min-accelerator type=nvidia-l4,count=1 \
  --max-accelerator type=nvidia-l4,count=10

# Verify Connection
gcloud container clusters get-credentials $CLUSTER_NAME \
    --zone=$ZONE \
    --project=$PROJECT_ID
```

---

## Task 3: Image Streaming Comparison
We will create two separate node pools to compare startup performance.

### 3.1 Create Standard Pool (No Streaming)
```bash
gcloud container node-pools create pool-std \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --image-type=COS_CONTAINERD \
  --no-enable-image-streaming \
  --machine-type=e2-standard-4 \
  --num-nodes=1
```

### 3.2 Streaming Node Pool (Image Streaming Enabled)
```bash
gcloud container node-pools create pool-streaming \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --image-type=COS_CONTAINERD \
  --enable-image-streaming \
  --machine-type=e2-standard-4 \
  --num-nodes=1
```

### 3.3 Run Comparison
Once the node pools are ready, run the comparison script:
```bash
./compare-startup.sh
```

---

## Task 4: Secondary Boot Disk

### 4.1 Build Disk Image
The builder tool pre-caches the heavy vLLM container image into a Google Cloud Image.

```bash
git clone https://github.com/ai-on-gke/tools.git
cd tools/gke-disk-image-builder
go run ./cli \
    --project-name=$PROJECT_ID \
    --image-name=$IMAGE_NAME \
    --zone=$ZONE \
    --gcs-path=gs://$BUCKET_NAME-logs \
    --disk-size-gb=100 \
    --container-image=docker.io/vllm/vllm-openai:v0.11.1
```

### 4.2 Allowlist 
Apply the allowlist to permit GKE node auto-provisioning to use your custom disk image:

```bash
cat <<EOF > secondary-allowlist.yaml
apiVersion: "node.gke.io/v1"
kind: GCPResourceAllowlist
metadata:
 name: gke-secondary-boot-disk-allowlist
spec:
 allowedResourcePatterns:
 - "projects/$PROJECT_ID/global/images/.*"
EOF

kubectl apply -f secondary-allowlist.yaml
```

### 4.3 Apply Compute Class
Create and apply the `l4` compute class:

```bash
cat <<EOF > custom-compute-class.yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: l4
spec:
  activeMigration:
    optimizeRulePriority: true
  nodePoolAutoCreation:
    enabled: true
  priorities:
    - gpu:
        count: 2
        driverVersion: latest
      machineType: g2-standard-24
      storage:
        secondaryBootDisks:
          - diskImageName: $IMAGE_NAME
            mode: CONTAINER_IMAGE_CACHE
  whenUnsatisfiable: ScaleUpAnyway
EOF

kubectl apply -f custom-compute-class.yaml
```

---

## Task 5: Configure Workload Identity & GCS Access

### 5.1 Create Google Service Account (GSA)
```bash
gcloud iam service-accounts create $GSA_NAME --project=$PROJECT_ID
```

### 5.2 Grant GSA access to your Model Bucket
The RunAI streamer and GCS Fuse both require read access to your model weights. We grant the `storage.objectViewer` role for reading objects and `storage.insightsCollectorServiceAccount` which is sometimes used for storage-related telemetry.

```bash
# Grant object viewer access to the bucket
gcloud storage buckets add-iam-policy-binding gs://$BUCKET_NAME \
   --member="serviceAccount:$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
   --role="roles/storage.objectViewer"

# (Optional) Grant bucket viewer access if the streamer needs to inspect bucket metadata
gcloud storage buckets add-iam-policy-binding gs://$BUCKET_NAME \
   --member="serviceAccount:$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
   --role="roles/storage.bucketViewer"
```

### 5.3 Create Kubernetes Service Account (KSA)
```bash
cat <<EOF > vllm-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
 name: $KSA_NAME
 namespace: default
 annotations:
   iam.gke.io/gcp-service-account: $GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com
EOF

kubectl apply -f vllm-sa.yaml
```

### 5.4 Bind KSA to GSA
```bash
gcloud iam service-accounts add-iam-policy-binding \
  $GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[default/$KSA_NAME]"
```

---

## Task 6: Deploy vLLM with GCS Fuse & RunAI Streamer
Deploy the inference servers. We will deploy two versions: one using GCS Fuse CSI driver and another using the RunAI Streamer for optimized weight loading.

```bash
# Update the bucket name in the GCS Fuse deployment
sed -i "s/bucketName: .*/bucketName: $BUCKET_NAME/" vllm-deployment.yaml

# Update the bucket name in the RunAI Streamer deployment
sed -i "s|--model=gs://.*/|--model=gs://$BUCKET_NAME/|" vllm-deployment-runai.yaml

# Apply both deployments
kubectl apply -f vllm-deployment.yaml
kubectl apply -f vllm-deployment-runai.yaml
```

---

## Task 7: Test Inference
Once the pods are `Running`, you can test either service.

### 7.1 Test GCS Fuse Service
```bash
kubectl port-forward svc/llm-service 8080:8080

# In a separate terminal:
curl http://localhost:8080/v1/completions \
 -H "Content-Type: application/json" \
 -d '{
   "model": "/models/gemma-3-12b-it",
   "prompt": "San Francisco is a",
   "max_tokens": 7,
   "temperature": 0
 }'
```

### 7.2 Test RunAI Streamer Service
```bash
# Kill previous port-forward and run:
kubectl port-forward svc/llm-service-runai 8081:8080

# In a separate terminal:
curl http://localhost:8081/v1/completions \
 -H "Content-Type: application/json" \
 -d '{
   "model": "gs://'$BUCKET_NAME'/gemma-3-12b-it",
   "prompt": "San Francisco is a",
   "max_tokens": 7,
   "temperature": 0
 }'
```

---

## Task 8: Verification
Confirm secondary boot disk cache usage:

```bash
gcloud logging read "logName=\"projects/$PROJECT_ID/logs/gcfs-snapshotter\" AND jsonPayload.MESSAGE:\"vllm\" AND jsonPayload.MESSAGE:\"backed by secondary boot disk caching by 100.0%\"" --format="value(jsonPayload.MESSAGE)" --limit=1
```

---

## Cleanup
```bash
gcloud container clusters delete $CLUSTER_NAME --zone $ZONE
gcloud iam service-accounts delete $GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com
```
