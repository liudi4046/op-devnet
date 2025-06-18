#!/bin/bash
set -e
source .env

# --- L1 Setup ---
echo "Starting L1..."
if [ ! -d "$ETH_POS_DEVNET_DIR" ]; then
    echo "Cloning eth-pos-devnet..."
    git clone "$ETH_POS_DEVNET_REPO" "$ETH_POS_DEVNET_DIR"
fi

(
  cd "$ETH_POS_DEVNET_DIR"
  ./clean.sh
  docker compose up -d
)

echo "Waiting for L1 RPC to be available inside the Docker network..."
until docker run --rm --network "$DOCKER_NETWORK" "$OP_STACK_IMAGE" cast chain-id --rpc-url "$L1_RPC_URL_IN_DOCKER" >/dev/null 2>&1; do
  sleep 1; echo -n ".";
done
echo " L1 RPC is ready."

echo "Checking for L1 network..."
if [ -z "$(docker network ls -q -f name=^${DOCKER_NETWORK}$)" ]; then
    echo "Error: Docker network '$DOCKER_NETWORK' not found."
    echo "Please start the L1 stack first by running 'docker compose up -d' in the 'eth-pos-devnet' directory."
    exit 1
fi
echo "L1 network found."




echo "Deploying L2 contracts to L1..."
sleep 30
docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/app/packages/contracts-bedrock/deployments" \
  -w /app/packages/contracts-bedrock \
  "$OP_STACK_IMAGE" \
  bash -c "yes | DEPLOYMENT_OUTFILE=deployments/artifact.json DEPLOY_CONFIG_PATH=deployments/devnetL1.json forge script -vvv scripts/deploy/Deploy.s.sol:Deploy \
      --rpc-url $L1_RPC_URL_IN_DOCKER \
      --broadcast --private-key $DEPLOYER_PRIVATE_KEY --non-interactive"