import { task } from "hardhat/config";
import * as graphAddresses from "@graphprotocol/contracts/addresses.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";
require("isomorphic-fetch");

const SUBGRAPH_BRIDGE_CONTRACT_ADDRESS =
  "0x74df809b1dfc099e8cdbc98f6a8d1f5c2c3f66f8";

const BRIDGE_QUERY_BLOCKS_BACK = 10;

const DEFAULT_QUERY_TEMPLATE_STRING =
  '{badgeWinner(block:{hash:""},id:"",first:){votingPower}}';
const DEFAULT_QUERY_VARIABLE_VALUES = [
  "0xf412716874ddcd23d81e2d94048e48c0ad965522",
  "1",
];
const DEFAULT_QUERY_BRIDGE: QueryBridge = {
  queryTemplate:
    "0x8c53762d54c02a8b9209b4d54ff280b24f6eb60b261833afba5783ace5e8c3ce", // keccack256(DEFAULT_QUERY_TEMPLATE_STRING)
  subgraphDeploymentID:
    "0x66b8f5c7569d0a1243428ebf1912ec1a7c33081fd2ef418228a18deb4acc98f1",
  blockHashOffset: 26,
  responseDataOffset: 40,
  responseDataType: 2,
  queryVariables: [0x6300, 0x0802],
  proposalFreezePeriod: 0,
  minimumSlashableGRT: 1,
  minimumExternalStake: 0,
  disputeResolutionWindow: 0,
  resolutionThresholdSlashableGRT: 50, // disputed proposals must have at least 50% stake to resolve
  resolutionThresholdExternalStake: 0,
  stakingToken: "0xc944E90C64B2c07662A292be6244BDf05Cda44a7", // GRT
};

task("deploySubgraphBridge", "Deploys SubgraphBridge contract").setAction(
  async (taskArgs, hre) => {
    const disputeManager = graphAddresses["1"]["DisputeManager"]["address"];
    const staking = graphAddresses["1"]["Staking"]["address"];
    const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
      "SubgraphBridge"
    );
    const subgraphBridgeContract = await subgraphBridgeContractFactory.deploy(
      staking,
      disputeManager
    );
    await subgraphBridgeContract.deployed();
    console.log(
      "SubgraphBridge contract deployed to: " + subgraphBridgeContract.address
    );
  }
);

task(
  "createQueryBridge",
  "creates a query bridge using DEFAULT_QUERY_BRIDGE"
).setAction(async (taskArgs, hre) => {
  await createQueryBridge(hre);
});

task(
  "pinQueryResponse",
  "pins a block hash to a query response proposal"
).setAction(async (taskArgs, hre) => {
  await getAttestation(hre, pinProposal);
});

task(
  "submitQueryResponse",
  "submits query response for block hashes that have already been pinned"
).setAction(async (taskArgs, hre) => {
  await getAttestation(hre, submitProposal);
});

task(
  "executeQueryResponse",
  "extracts data from query response if default strategy requirements are fulfilled"
).setAction(async (taskArgs, hre) => {
  await executeProposal(hre);
});

task("readDataStream", "reads from a data stream of secured data").setAction(
  async (taskArgs, hre) => {
    await readDataStream(hre);
  }
);

task("testStringToUint", "tests SubgraphBridge._strToUint").setAction(
  async (taskArgs, hre) => {
    await testStringToUint(hre);
  }
);

async function testStringToUint(hre: HardhatRuntimeEnvironment) {
  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );

  const testString = "atfjdidididisldke50777830}youwill";
  const testNum = await subgraphBridgeContract._uintFromString(testString, 18);
  console.log("the extracted number is " + testNum);
}

async function createQueryBridge(hre: HardhatRuntimeEnvironment) {
  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );

  await subgraphBridgeContract.createQueryBridge(DEFAULT_QUERY_BRIDGE);
}

async function pinProposal(
  hre: HardhatRuntimeEnvironment,
  attestation: string,
  response: string
) {
  console.log(attestation);
  const parsedAttestation = JSON.parse(attestation) as Attestation;

  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );
  const attestationData = attestationBytesFromJSON(hre, parsedAttestation);
  const bQuery = await bridgeQuery(hre);
  console.log("Bridge Query: " + bQuery);
  const bQueryBlockNumber =
    (await hre.ethers.provider.getBlockNumber()) - BRIDGE_QUERY_BLOCKS_BACK;

  await subgraphBridgeContract.pinQueryBridgeProposal(
    bQueryBlockNumber,
    bQuery,
    response,
    defaultQueryBridgeID(hre),
    attestationData
  );
}

async function submitProposal(
  hre: HardhatRuntimeEnvironment,
  attestation: string,
  response: string
) {
  const parsedAttestation = JSON.parse(attestation) as Attestation;

  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );
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
  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );

  const bridgeID = defaultQueryBridgeID(hre);
  const queryString = await subgraphBridgeContract.test_queries(0);
  const requestCID = await subgraphBridgeContract.test_requestCIDs(0);
  const responseString = await subgraphBridgeContract.test_queryResponses(0);

  await subgraphBridgeContract.executeProposal(
    queryString,
    requestCID,
    responseString,
    defaultQueryBridgeID(hre)
  );
}

async function readDataStream(hre: HardhatRuntimeEnvironment) {
  const subgraphBridgeContractFactory = await hre.ethers.getContractFactory(
    "SubgraphBridge"
  );
  const subgraphBridgeContract = await subgraphBridgeContractFactory.attach(
    SUBGRAPH_BRIDGE_CONTRACT_ADDRESS
  );

  const requestCID = await subgraphBridgeContract.test_requestCIDs(0);
  const d = await subgraphBridgeContract.dataStreams(
    defaultQueryBridgeID(hre),
    requestCID
  );
  console.log("data stream: " + d);
}

async function getAttestation(
  hre: HardhatRuntimeEnvironment,
  callback: BridgeProposal
) {
  const bQuery = await bridgeQuery(hre);
  const query = JSON.stringify({ query: bQuery, variables: {} });
  const gatewayEndpoint = process.env.THE_GRAPH_GATEWAY_ENDPOINT as string;
  const badgeRequest = new Request(gatewayEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: query,
  });

  var attestation: string;
  await fetch(badgeRequest)
    .then((response) => {
      attestation = response.headers.get("graph-attestation")!;
      return response.text();
    })
    .then(async (text) => {
      console.log(text);
      await callback(hre, attestation, text);
    });
}

// returns bridge query containing block hash of 10th most recent block
async function bridgeQuery(hre: HardhatRuntimeEnvironment) {
  const blockNumberToQuery =
    (await hre.ethers.provider.getBlockNumber()) - BRIDGE_QUERY_BLOCKS_BACK;
  const queryBlock = await hre.ethers.provider.getBlock(blockNumberToQuery);

  let bQuery =
    DEFAULT_QUERY_TEMPLATE_STRING.substring(
      0,
      DEFAULT_QUERY_BRIDGE.blockHashOffset
    ) + queryBlock.hash;
  if (DEFAULT_QUERY_VARIABLE_VALUES[0] == "") {
    bQuery += DEFAULT_QUERY_TEMPLATE_STRING.substring(
      DEFAULT_QUERY_BRIDGE.blockHashOffset + 66
    );
  } else {
    const qv0Idx = (DEFAULT_QUERY_BRIDGE.queryVariables[0] >> 8) - 66;
    bQuery +=
      DEFAULT_QUERY_TEMPLATE_STRING.substring(
        DEFAULT_QUERY_BRIDGE.blockHashOffset,
        qv0Idx
      ) + DEFAULT_QUERY_VARIABLE_VALUES[0];
    if (DEFAULT_QUERY_VARIABLE_VALUES[1] == "") {
      bQuery += DEFAULT_QUERY_TEMPLATE_STRING.substring(qv0Idx);
    } else {
      const qv1Idx = qv0Idx + (DEFAULT_QUERY_BRIDGE.queryVariables[1] >> 8);
      bQuery +=
        DEFAULT_QUERY_TEMPLATE_STRING.substring(qv0Idx, qv1Idx) +
        DEFAULT_QUERY_VARIABLE_VALUES[1] +
        DEFAULT_QUERY_TEMPLATE_STRING.substring(qv1Idx);
    }
  }

  return bQuery;
}

interface Attestation {
  requestCID: string;
  responseCID: string;
  subgraphDeploymentID: string;
  r: string;
  s: string;
  v: number;
}

interface BridgeProposal {
  (hre: HardhatRuntimeEnvironment, attestation: string, response: string): void;
}

interface QueryBridge {
  queryTemplate: string;
  subgraphDeploymentID: string;
  blockHashOffset: number;
  responseDataOffset: number;
  responseDataType: number;
  queryVariables: [number, number];
  proposalFreezePeriod: number;
  minimumSlashableGRT: number;

  // dispute handling
  minimumExternalStake: number;
  disputeResolutionWindow: number;
  resolutionThresholdSlashableGRT: number;
  resolutionThresholdExternalStake: number;
  stakingToken: string;
}

function queryBridgeID(
  hre: HardhatRuntimeEnvironment,
  queryBridge: QueryBridge
) {
  const encodedBridge = hre.ethers.utils.defaultAbiCoder.encode(
    [
      "bytes32",
      "bytes32",
      "uint16",
      "uint16",
      "uint8",
      "uint16[2]",
      "uint8",
      "uint8",
      "uint8",
      "uint8",
      "uint8",
      "uint8",
      "address",
    ],
    [
      queryBridge.queryTemplate,
      queryBridge.subgraphDeploymentID,
      queryBridge.blockHashOffset,
      queryBridge.responseDataOffset,
      queryBridge.responseDataType,
      queryBridge.queryVariables,
      queryBridge.proposalFreezePeriod,
      queryBridge.minimumSlashableGRT,
      queryBridge.minimumExternalStake,
      queryBridge.disputeResolutionWindow,
      queryBridge.resolutionThresholdSlashableGRT,
      queryBridge.resolutionThresholdExternalStake,
      queryBridge.stakingToken,
    ]
  );

  return hre.ethers.utils.keccak256(encodedBridge);
}

function defaultQueryBridgeID(hre: HardhatRuntimeEnvironment) {
  return queryBridgeID(hre, DEFAULT_QUERY_BRIDGE);
}

function defaultQueryTemplateHash(hre: HardhatRuntimeEnvironment) {
  const encodedQueryTemplate = hre.ethers.utils.defaultAbiCoder.encode(
    ["string"],
    [DEFAULT_QUERY_TEMPLATE_STRING]
  );

  return hre.ethers.utils.keccak256(encodedQueryTemplate);
}

function attestationBytesFromJSON(
  hre: HardhatRuntimeEnvironment,
  attestation: Attestation
) {
  return hre.ethers.utils.hexConcat([
    attestation.requestCID,
    attestation.responseCID,
    attestation.subgraphDeploymentID,
    attestation.r,
    attestation.s,
    hre.ethers.utils.hexlify(attestation.v),
  ]);
}
