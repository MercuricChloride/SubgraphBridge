import { task } from "hardhat/config";
import * as graphAddresses from "@graphprotocol/contracts/addresses.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";
require("isomorphic-fetch");

const SUBGRAPH_BRIDGE_CONTRACT_ADDRESS = "0x547382C0D1b23f707918D3c83A77317B71Aa8470";

const BRIDGE_QUERY_BLOCKS_BACK = 10;

const DEFAULT_QUERY_TEMPLATE_STRING = "{earnedBadges(first:1,orderBy:blockAwarded,orderDirection:desc,block:{hash:\"\"}){transactionHash}}";
const DEFAULT_QUERY_BRIDGE: QueryBridge = {
    queryTemplate: "0xb99f5bca1efe856274c3e77ffc53804e487f7a11ec88fa040784e2973d481867",
    subgraphDeploymentID: "0x66b8f5c7569d0a1243428ebf1912ec1a7c33081fd2ef418228a18deb4acc98f1",
    blockHashOffset: 76,
    responseDataOffset: 47,
    proposalFreezePeriod: 0,
    minimumSlashableGRT: 1,
    minimumExternalStake: 0,
    disputeResolutionWindow: 0,
    resolutionThresholdSlashableGRT: 50,    // disputed proposals must have at least 50% stake to resolve
    resolutionThresholdExternalStake: 0,
    stakingToken: "0xc944E90C64B2c07662A292be6244BDf05Cda44a7" // GRT
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

task("createQueryBridge", "creates a query bridge using DEFAULT_QUERY_BRIDGE")
.setAction(async (taskArgs, hre) => {
    await createQueryBridge(hre);
})

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

async function createQueryBridge(hre: HardhatRuntimeEnvironment) {
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    await subgraphBridgeContract.hashQueryTemplate(DEFAULT_QUERY_BRIDGE.queryTemplate);

    await subgraphBridgeContract.createQueryBridge(DEFAULT_QUERY_BRIDGE);
    const qID = await defaultQueryBridgeID(hre);
    console.log("query bridge ID: " + qID);
}

async function pinProposal(hre: HardhatRuntimeEnvironment, attestation: string, response: string) {
    const parsedAttestation = JSON.parse(attestation) as Attestation;

    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
    const bQuery = await bridgeQuery(hre);
    console.log("Bridge Query: " + bQuery);
    const bQueryBlockNumber = await hre.ethers.provider.getBlockNumber() - BRIDGE_QUERY_BLOCKS_BACK;

    await subgraphBridgeContract.pinQueryBridgeProposal(
        bQueryBlockNumber,
        bQuery,
        response,
        defaultQueryBridgeID(hre),
        attestationData
    );
}

async function submitProposal(hre: HardhatRuntimeEnvironment, attestation: string, response: string) {
    const parsedAttestation = JSON.parse(attestation) as Attestation;

    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);
    const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
    const bQuery = await bridgeQuery(hre);
    console.log("Bridge Query: " + bQuery);

    await subgraphBridgeContract.submitQueryBridgeProposal(
        bQuery,
        response,
        defaultQueryBridgeID(hre),
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
        defaultQueryBridgeID(hre)
    );
}

async function readDataStream(hre: HardhatRuntimeEnvironment) {
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory("SubgraphBridge");
    const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(SUBGRAPH_BRIDGE_CONTRACT_ADDRESS);

    const queryBlockHash = await subgraphBridgeContract.test_pinnedBlocks(0);
    const d = await subgraphBridgeContract.dataStreams(defaultQueryBridgeID(hre), queryBlockHash);
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

   return DEFAULT_QUERY_TEMPLATE_STRING.substring(0, DEFAULT_QUERY_BRIDGE.blockHashOffset) + 
        blockToQuery.hash + 
        DEFAULT_QUERY_TEMPLATE_STRING.substring(DEFAULT_QUERY_BRIDGE.blockHashOffset);
}

interface Attestation {
    requestCID: string,
    responseCID: string,
    subgraphDeploymentID: string,
    r: string,
    s: string,
    v: number
}

interface BridgeProposal {
    (hre: HardhatRuntimeEnvironment, attestation: string, response: string): void;
}

interface QueryBridge {
    queryTemplate: string,
    subgraphDeploymentID: string,
    blockHashOffset: number
    responseDataOffset: number,
    proposalFreezePeriod: number,
    minimumSlashableGRT: number,

    // dispute handling
    minimumExternalStake: number,
    disputeResolutionWindow: number,
    resolutionThresholdSlashableGRT: number,
    resolutionThresholdExternalStake: number,
    stakingToken: string
}

function queryBridgeID(hre: HardhatRuntimeEnvironment, queryBridge: QueryBridge) {
    const encodedBridge = hre.ethers.utils.defaultAbiCoder.encode(["bytes32","bytes32","uint16","uint16","uint8","uint8","uint8","uint8","uint8","uint8","address"], [
        queryBridge.queryTemplate,
        queryBridge.subgraphDeploymentID,
        queryBridge.blockHashOffset,
        queryBridge.responseDataOffset,
        queryBridge.proposalFreezePeriod,
        queryBridge.minimumSlashableGRT,
        queryBridge.minimumExternalStake,
        queryBridge.disputeResolutionWindow,
        queryBridge.resolutionThresholdSlashableGRT,
        queryBridge.resolutionThresholdExternalStake,
        queryBridge.stakingToken
    ]);

    return hre.ethers.utils.keccak256(encodedBridge);
}

function defaultQueryBridgeID(hre: HardhatRuntimeEnvironment) {
    return queryBridgeID(hre, DEFAULT_QUERY_BRIDGE);
}

function defaultQueryTemplateHash(hre: HardhatRuntimeEnvironment) {
    const encodedQueryTemplate = hre.ethers.utils.defaultAbiCoder.encode(["string"], [
        DEFAULT_QUERY_BRIDGE.queryTemplate
    ]);

    return hre.ethers.utils.keccak256(encodedQueryTemplate);
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
