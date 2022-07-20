import { task } from "hardhat/config";
import * as graphAddresses from "@graphprotocol/contracts/addresses.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";
require("isomorphic-fetch");

const SUBGRAPH_BRIDGE_CONTRACT_ADDRESS = "0xAe120F0df055428E45b264E7794A18c54a2a3fAF";

const BRIDGE_QUERY_BLOCKS_BACK = 10;
const QUERY_BRIDGE_SUBGRAPH_DEPLOYMENT_ID = "0x66b8f5c7569d0a1243428ebf1912ec1a7c33081fd2ef418228a18deb4acc98f1";
const BRIDGE_QUERY_STRIPPED_STRING = "{earnedBadges(first:1,orderBy:blockAwarded,orderDirection:desc,block:{hash:\"\"}){transactionHash}}";


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

task("pinQueryResponse", "pins a block hash to a query response proposal")
.setAction(async (taskArgs, hre) => {
    await getAttestation(hre, pinProposal);
});

task("submitQueryResponse", "submits query response for block hashes that have already been pinned")
.setAction(async (taskArgs, hre) => {
    await getAttestation(hre, submitProposal);
});

task("executeQueryResponse", "extracts data from query response if default strategy requirements are fulfilled")
.setAction(async (taskArgs, hre) => {
    await executeProposal(hre);
});

task("readDataStream", "reads from a data stream of secured data")
.setAction(async (taskArgs, hre) => {
    await readDataStream(hre);
});

async function pinProposal(hre: HardhatRuntimeEnvironment, attestation: string, response: string) {
    const parsedAttestation = JSON.parse(attestation) as Attestation;

    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
    const bQuery = await bridgeQuery(hre);
    const bQueryBlockNumber = await hre.ethers.provider.getBlockNumber() - BRIDGE_QUERY_BLOCKS_BACK;

    await subgraphBridgeContract.pinQueryBridgeProposal(
        bQueryBlockNumber,
        bQuery,
        response,
        DEFAULT_QUERY_BRIDGE_STRATEGY.requestBlockHashOffset,
        attestationData
    );
}

async function submitProposal(hre: HardhatRuntimeEnvironment, attestation: string, response: string) {
    const parsedAttestation = JSON.parse(attestation) as Attestation;

    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
    console.log("submitting attestation to bridge:\n" + attestation + "\n");
    const bQuery = await bridgeQuery(hre);
    await subgraphBridgeContract.submitQueryBridgeProposal(
        bQuery,
        response,
        DEFAULT_QUERY_BRIDGE_STRATEGY.requestBlockHashOffset+2,
        attestationData
    );
}

async function executeProposal(hre: HardhatRuntimeEnvironment) {
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);

    const bridgeID = defaultQueryBridgeID(hre);
    const queryString = await subgraphBridgeContract.test_queries(0);    // todo: 0 -> parameter
    const requestCID = await subgraphBridgeContract.test_requestCIDs(0);
    const responseString = await subgraphBridgeContract.test_queryResponses(0);

    console.log("query bridgeID: " + bridgeID);
    console.log("queryString: " + queryString);
    console.log("requestCID: " + requestCID);
    console.log("responseString: " + responseString);

    const proposal = await subgraphBridgeContract.queryBridgeProposals(bridgeID, requestCID);
    console.log(proposal);

    await subgraphBridgeContract.executeProposal(
        queryString, 
        requestCID, 
        responseString, 
        QUERY_BRIDGE_SUBGRAPH_DEPLOYMENT_ID,
        DEFAULT_QUERY_BRIDGE_STRATEGY
    );
}

async function readDataStream(hre: HardhatRuntimeEnvironment) {
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);

    const dataStreamID = await subgraphBridgeContract.test_dataStreamIDs(0);
    const queryBlockHash = await subgraphBridgeContract.test_pinnedBlockHashes(0);
    // todo: compute dataStreamID and block hash
    const d = await subgraphBridgeContract.dataStreams(dataStreamID, queryBlockHash);
    console.log("data stream: " + d);
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

    const q = BRIDGE_QUERY_STRIPPED_STRING.substring(0, DEFAULT_QUERY_BRIDGE_STRATEGY.requestBlockHashOffset) + 
        blockToQuery.hash + 
        BRIDGE_QUERY_STRIPPED_STRING.substring(DEFAULT_QUERY_BRIDGE_STRATEGY.requestBlockHashOffset);
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


interface QueryBridgeStrategy {
    requestBlockHashOffset: number
    responseDataOffset: number,
    proposalFreezePeriod: number,
    minimumSlashableGRT: number,

    // not yet implemented
    minimumExternalStake: number,
    stakingToken: string,
    disputeResolutionWindow: number,
    resolutionThresholdSlashableGRT: number,
    resolutionThresholdExternalStake: number
}

const DEFAULT_QUERY_BRIDGE_STRATEGY: QueryBridgeStrategy = {
    requestBlockHashOffset: 76,
    responseDataOffset: 47,
    proposalFreezePeriod: 0,
    minimumSlashableGRT: 1,
    minimumExternalStake: 0,
    stakingToken: "0xc944E90C64B2c07662A292be6244BDf05Cda44a7", // GRT
    disputeResolutionWindow: 0,
    resolutionThresholdSlashableGRT: 50,    // disputed proposals must have at least 50% stake to resolve
    resolutionThresholdExternalStake: 0
}

function queryBridgeID(hre: HardhatRuntimeEnvironment, strippedQueryHash: string, subgraphDeploymentID: string) {
    const encodedBridge = hre.ethers.utils.defaultAbiCoder.encode(["bytes32","bytes32"], [
        strippedQueryHash,
        subgraphDeploymentID
    ]);

    return hre.ethers.utils.keccak256(encodedBridge);
}

function defaultQueryBridgeID(hre: HardhatRuntimeEnvironment) {
    return queryBridgeID(hre, strippedBridgeQueryHash(hre), QUERY_BRIDGE_SUBGRAPH_DEPLOYMENT_ID);
}

function strippedBridgeQueryHash(hre: HardhatRuntimeEnvironment) {
    return hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes(BRIDGE_QUERY_STRIPPED_STRING));
};

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
