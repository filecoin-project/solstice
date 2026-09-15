# solstice
Supporting contracts and tools for https://github.com/filecoin-project/FIPs/discussions/1249

## DeployScript
Run with [`forge`](https://www.getfoundry.sh/).
```sh
# List known keystore accounts
cast wallet list
# Specify your signing wallet
export ETH_KEYSTORE_ACCOUNT=<account name>

# Mainnet
ETH_RPC_URL=https://api.node.glif.io/rpc/v1
# Calibration
ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1

# Deploy all
forge script script/Deploy.s.sol --broadcast --verify --rpc-url $ETH_RPC_URL --skip-simulation
```
