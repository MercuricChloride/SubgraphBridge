# Subgraph Bridge

The purpose of a subgraph bridge is to utilize The Graph's decentralized network as a computation oracle for EVM compatible blockchains. This allows smart contracts to consume subgraph-derived data with configurable cryptoeconomic security requirements. Verifiable queries with shell proofs will eventually allow smart contracts to verify the integrity of subgraph queries during execution. This unlocks new subgraph-centric design patterns which can be emulated with a subgraph bridge given configurable sacrifices to decentralization, speed, and capital efficiency.

# Testing
To properly test the bridge we need to fork mainnet from a recent block so that the allocations referred to by Indexer attestations are available in the staking contract. The following is a useful setup for testing. Run ```npm install``` first to install all dependencies.

1. Set ```MAINNET_URL``` in ```.env``` to an Ethereum archive node. Alchemy offers this for free.
2. Set ```THE_GRAPH_GATEWAY_ENDPOINT``` in ```.env``` to the Emblem subgraph running on the decentralized network with your consumer API key. Example: https://gateway.thegraph.com/api/[api-key]/subgraphs/id/BKWqzRUajb4zK3X8LwwEACH2tVgprgEE8ZdsHdknxQEk
3. Set ```networks.hardhat.forking.blockNumber``` in ```hardhat.config.ts``` to a recent mainnet blocknumber. Forking from an old block number may result in the staking contract not having the required Indexer allocations. Forking offers Hardhat efficiency gains via block pinning and provides a consistent state to test against.
4. Compile the smart contracts: ```npx hardhat compile```
5. Start a local Hardhat node in a new shell: ```npx hardhat node```
6. Deploy a SubgraphBridge contract: ```npx hardhat deploySubgraphBridge --network localhost```
7. Set ```SUBGRAPH_BRIDGE_CONTRACT_ADDRESS``` in ```bridge-tasks.ts``` to the address logged in #6.
8. Create a query bridge with default values and {badgeWinner(block:{hash:""},id:"",first:){votingPower}} query template: ```npx hardhat createQueryBridge --network localhost```
9. Query The Graph's Decentralized Network and submit response and indexer attestation to the QueryBridge: ```npx hardhat pinQueryResponse --network localhost```
10. Push response to data stream: ```npx hardhat executeQueryResponse --network localhost```
11. Read from data stream: ```npx hardhat readDataStream --network localhost```
