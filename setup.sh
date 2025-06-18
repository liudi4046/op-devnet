#!/bin/bash
set -e
source .env

# # --- Pull Docker Images ---
# echo "--- Pulling required Docker images"
# # Pull the image for op-geth
# docker pull "${DOCKER_HUB_USERNAME}/${OP_GETH_IMAGE_TAG}"
# # Pull the image used for op-node, op-batcher, op-proposer, and contract deployment
# docker pull "${DOCKER_HUB_USERNAME}/${OP_STACK_IMAGE_TAG}"
# echo "Docker images pulled successfully."


# --- L1 Setup ---
echo "Starting L1..."
if [ ! -d "$ETH_POS_DEVNET_DIR" ]; then
    echo "Cloning eth-pos-devnet..."
    git clone "$ETH_POS_DEVNET_REPO" "$ETH_POS_DEVNET_DIR"
fi
docker compose down -v

(
  cd "$ETH_POS_DEVNET_DIR"
  ./clean.sh
  docker compose up -d
)


echo "Checking for L1 network..."
if [ -z "$(docker network ls -q -f name=^${DOCKER_NETWORK}$)" ]; then
    echo "Error: Docker network '$DOCKER_NETWORK' not found."
    echo "Please start the L1 stack first by running 'docker compose up -d' in the 'eth-pos-devnet' directory."
    exit 1
fi
echo "L1 network found."

echo "Deploying contracts to L1..."

sleep 30
docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/$CONFIG_DIR:/app/packages/contracts-bedrock/deployments" \
  -w /app/packages/contracts-bedrock \
  "${DOCKER_HUB_USERNAME}/${OP_STACK_IMAGE_TAG}" \
  bash -c "yes | DEPLOYMENT_OUTFILE=deployments/artifact.json DEPLOY_CONFIG_PATH=deployments/devnetL1.json forge script -vvv scripts/deploy/Deploy.s.sol:Deploy \
      --rpc-url $L1_RPC_URL_IN_DOCKER \
      --broadcast --private-key $DEPLOYER_PRIVATE_KEY --non-interactive && \
      FORK=latest STATE_DUMP_PATH=deployments/state_dump.json DEPLOY_CONFIG_PATH=deployments/devnetL1.json CONTRACT_ADDRESSES_PATH=deployments/artifact.json forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()' &&\
      go run ../../op-node/cmd/main.go genesis l2 \
      --deploy-config=deployments/devnetL1.json \
      --l1-deployments=deployments/artifact.json \
      --l2-allocs=deployments/state_dump.json \
      --outfile.l2=deployments/genesis.json \
      --outfile.rollup=deployments/rollup.json \
      --l1-rpc=$L1_RPC_URL_IN_DOCKER"

echo "genesis.json and rollup.json are generated in deployments folder"

mkdir -p jwt
openssl rand -hex 32 > jwt/jwt.txt

# Run op-geth or op-reth

OP_GETH_DATADIR="$(pwd)/op-geth-datadir"

rm -rf "$OP_GETH_DATADIR"
mkdir -p "$OP_GETH_DATADIR"

docker compose run --rm --no-deps \
  -v "$(pwd)/config/genesis.json:/genesis.json" \
  op-geth \
  --datadir "/datadir" \
  --gcmode=archive \
  init \
  --state.scheme=hash \
  /genesis.json

echo "finished init op-geth"

if ! command -v jq &> /dev/null; then
    echo "Warning: 'jq' is not installed. The op-proposer service will fail if you try to run it."
    echo "Please install jq (e.g., 'sudo apt-get install jq' or 'brew install jq')."
else
    # Export the variable so docker-compose can access it.
    export L2OO_ADDRESS=$(jq -r .L2OutputOracleProxy "$(pwd)/config/artifact.json")
    if [ -z "$L2OO_ADDRESS" ] || [ "$L2OO_ADDRESS" == "null" ]; then
        echo "Warning: L2OutputOracleProxy address not found in deployments/artifact.json. op-proposer will fail if started."
    else
        echo "L2OutputOracleProxy address set for op-proposer: $L2OO_ADDRESS"
    fi
fi

echo "Starting core L2 services (op-geth, op-node)..."
docker compose up -d

