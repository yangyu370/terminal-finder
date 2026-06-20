#!/usr/bin/env bash
set -euo pipefail

endpoint="http://localhost:9000"
mc_endpoint="http://minioadmin:minioadmin@host.docker.internal:9000"

for _ in {1..30}; do
  if curl -sf "${endpoint}/minio/health/live" >/dev/null; then
    break
  fi
  sleep 1
done

curl -sf "${endpoint}/minio/health/live" >/dev/null

docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -e "MC_HOST_local=${mc_endpoint}" \
  minio/mc:latest mb --ignore-existing local/test-bucket

docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)/dev/fixtures:/fixtures:ro" \
  -e "MC_HOST_local=${mc_endpoint}" \
  minio/mc:latest cp --recursive /fixtures/ local/test-bucket/

echo "MinIO bucket 'test-bucket' provisioned with fixtures."
