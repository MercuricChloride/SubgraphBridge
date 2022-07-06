import { task } from "hardhat/config";
import * as graphAddresses from "@graphprotocol/contracts/addresses.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";
require("isomorphic-fetch");

const SUBGRAPH_BRIDGE_CONTRACT_ADDRESS = "0xcD0048A5628B37B8f743cC2FeA18817A29e97270";

// Bridge Query must specify block hash of a block no more than 256 blocks old.
const BRIDGE_QUERY_BLOCKS_BACK = 10;
const BRIDGE_QUERY_START = "{earnedBadges(first:1,orderBy:blockAwarded,orderDirection:desc,block:{hash:\"";
const BRIDGE_QUERY_END = "\"}){transactionHash}}";

interface BridgeProposal {
    (hre: HardhatRuntimeEnvironment, attestation: string, response: string): void;
}
 
task("deploySubgraphBridge", "Deploys SubgraphBridge contract")
.setAction(async (taskArgs, hre) => {
    const disputeManager = graphAddresses["1"]["DisputeManager"]["address"];
    const staking = graphAddresses["1"]["Staking"]["address"];
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.deploy(staking, disputeManager);
    await subgraphBridgeContract.deployed();
    console.log("SubgraphBridge contract deployed to: " + subgraphBridgeContract.address);
});

task("createBridgeProposal", "Submits new state hash and indexer attestation to SubgraphBridge contract.")
.setAction(async (taskArgs, hre) => {
    await getAttestation(hre, submitProposal);
});

async function submitProposal(hre: HardhatRuntimeEnvironment, attestation: string, response: string) {
    const parsedAttestation = JSON.parse(attestation) as Attestation;

    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
    console.log(attestation);
    const bQuery = await bridgeQuery(hre);
    const bQueryBlockNumber = await hre.ethers.provider.getBlockNumber() - BRIDGE_QUERY_BLOCKS_BACK;
    await subgraphBridgeContract.submitProposal(
        bQueryBlockNumber,
        bQuery,
        response,
        attestationData
    );
}

async function getAttestation(hre: HardhatRuntimeEnvironment, callback: BridgeProposal) {
    const bQuery = await bridgeQuery(hre);
    const query = JSON.stringify({ query: bQuery, variables: {} });
    const gatewayEndpoint = process.env.THE_GRAPH_GATEWAY_ENDPOINT as string;
    const badgeRequest = new Request(gatewayEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: query
    });

    var attestation: string;
    await fetch(badgeRequest)
    .then(response => {
        attestation = response.headers.get('graph-attestation')!;
        return response.text();
    })
    .then(async text => {
        await callback(hre, attestation, text);
    });
}

// returns bridge query containing block hash of 10th most recent block
async function bridgeQuery(hre: HardhatRuntimeEnvironment) {
    const blockNumberToQuery = await hre.ethers.provider.getBlockNumber() - BRIDGE_QUERY_BLOCKS_BACK;
    const blockToQuery = await hre.ethers.provider.getBlock(blockNumberToQuery);
    const q = BRIDGE_QUERY_START + blockToQuery.hash + BRIDGE_QUERY_END;
    console.log("Bridge Query: " + q);
    return q;
}

interface Attestation {
    requestCID: string,
    responseCID: string,
    subgraphDeploymentID: string,
    r: string,
    s: string,
    v: number
}

function attestationBytesFromJSON(hre: HardhatRuntimeEnvironment, attestation: Attestation) {
    return hre.ethers.utils.hexConcat([
        attestation.requestCID, 
        attestation.responseCID, 
        attestation.subgraphDeploymentID, 
        attestation.r, 
        attestation.s, 
        hre.ethers.utils.hexlify(attestation.v)
    ]);
}
