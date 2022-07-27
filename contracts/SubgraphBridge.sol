// SPDX-License-Identifier: MIT

import "hardhat/console.sol";
import "./dependencies/TheGraph/IController.sol";
import "./dependencies/TheGraph/IStaking.sol";
import "./dependencies/TheGraph/IDisputeManager.sol";

pragma solidity ^0.8.0;



contract SubgraphBridge {

    address public theGraphStaking;
    address public theGraphDisputeManager;

    // stored in mapping where (ID == attestation.requestCID)
    struct QueryBridgeProposals {
        // {attestation.responseCID} -> {stake}
        mapping (bytes32 => BridgeStake) stake;
        BridgeStakeTokens totalStake;
        uint256 proposalCount;
    }

    struct BridgeStake {
        BridgeStakeTokens totalStake;
        mapping (address => BridgeStakeTokens) accountStake;
    }

    struct BridgeStakeTokens {
        uint256 attestationStake;   // Slashable GRT staked by indexers via the staking contract
        uint256 tokenStake;         // GRT staked by oracles through Subgraph Bridge contract
    }

    struct QueryBridge {
        bytes32 queryTemplate;                      // hash of query stripped of all query variables
        bytes32 subgraphDeploymentID;               // subgraph being queried
        uint16 blockHashOffset;                     // where the pinned block hash starts in the query string
        uint16 responseDataOffset;                  // index where the data starts in the response string
        
        // security requirements native to The Graph
        uint8 proposalFreezePeriod;                 // undisputed queries can only be executed after this many blocks
        uint8 minimumSlashableGRT;                  // minimum slashable GRT staked by indexers in order for undisputed proposal to pass

        // dispute handling config
        uint8 minimumExternalStake;                 // minimum external tokens staked in order for undisputed proposal to pass
        uint8 disputeResolutionWindow;              // how many blocks it takes for disputes to be settled (0 indicates no dispute resolution)
        uint8 resolutionThresholdSlashableGRT;      // (30-99) percent of slashable GRT required for dispute resolution
        uint8 resolutionThresholdExternalStake;     // (30-99) percentage of external stake required for dispute resolution
        address stakingToken;                       // erc20 token for external staking
    }

    function _queryBridgeID(QueryBridge memory queryBridge) public view returns (bytes32) {
        return keccak256(abi.encode(
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
        ));
    }


    // returns keccak of query string without block hash
    // todo: support other query variables (address, BigInt)
    function _generateQueryTemplateHash(
        string calldata query,
        uint256 blockHashOffset
    ) public view returns (bytes32) {
        bytes memory queryTemplate = bytes.concat(
            bytes(query)[:blockHashOffset],
            bytes(query)[blockHashOffset+66:]
        );
        return keccak256(queryTemplate);
    }

    // {block hash} -> {block number}
    mapping (bytes32 => uint256) public pinnedBlocks;

    // {QueryBridgeID} -> {QueryBridge}
    mapping (bytes32 => QueryBridge) public queryBridges;

    // {QueryBridgeID} -> {attestation.requestCID} -> {QueryBridgeProposals}
    mapping (bytes32 => mapping (bytes32 => QueryBridgeProposals)) public queryBridgeProposals;

    // not yet implemented
    // {QueryBridgeID} -> {query block hash} -> {block number}
    mapping (bytes32 => mapping (bytes32 => uint256)) public bridgeConflictResolutionBlock;

    // {QueryBridgeID} -> {block hash} -> {responseData}
    mapping (bytes32 => mapping (bytes32 => bytes32)) public dataStreams;

    ///////////////////////////////////////////////
    // not needed in production. useful for testing 
    string[] public test_queries;
    bytes32[] public test_requestCIDs;
    string[] public test_queryResponses;
    bytes32[] public test_pinnedBlocks;
    bytes32[] public test_dataStreamIDs;
    ///////////////////////////////////////////////

    constructor(address staking, address disputeManager) {
        theGraphStaking = staking;
        theGraphDisputeManager = disputeManager;
    }

    function hashQueryTemplate(string memory queryTemplate) public {
        bytes32 queryTemplateHash = keccak256(abi.encode(queryTemplate));
        console.logBytes32(queryTemplateHash);
    }

    function createQueryBridge(QueryBridge memory queryBridge) public {
        bytes32 queryBridgeID = _queryBridgeID(queryBridge);
        queryBridges[queryBridgeID] = queryBridge;
        console.log("created query bridge with id: ");
        console.logBytes32(queryBridgeID);
    }

    function pinBlockHash(uint256 blockNumber) public {
        pinnedBlocks[blockhash(blockNumber)] = blockNumber;
    }

    function pinQueryBridgeProposal(
        uint256 blockNumber,
        string calldata query,
        string calldata response,
        bytes32 queryBridgeID,
        bytes calldata attestationData
    ) public {
        bytes32 pinnedBlockHash = blockhash(blockNumber);
        pinnedBlocks[pinnedBlockHash] = blockNumber;

        console.log("pinned block hash:::");
        console.logBytes32(pinnedBlockHash);
        test_pinnedBlocks.push(pinnedBlockHash);
        
        submitQueryBridgeProposal(query, response, queryBridgeID, attestationData);
    }


    function submitQueryBridgeProposal(
        string calldata query,      // only needed for emitting event
        string calldata response,   // only needed for emitting event
        bytes32 queryBridgeID,
        bytes calldata attestationData
    ) public {
        require(queryBridges[queryBridgeID].blockHashOffset > 0, "query bridge doesn't exist");
        
        IDisputeManager.Attestation memory attestation = _parseAttestation(attestationData);
        require(_queryAndResponseMatchAttestation(query, response, attestation), "query/response != attestation");

        // get indexer's slashable stake from staking contract
        address attestationIndexer = IDisputeManager(theGraphDisputeManager).getAttestationIndexer(attestation);
        uint256 indexerStake = IStaking(theGraphStaking).getIndexerStakedTokens(attestationIndexer);
        require(indexerStake > 0, "indexer doesn't have slashable stake");

        console.log("indexer stake:::");
        console.log(indexerStake);

        QueryBridgeProposals storage proposals = queryBridgeProposals[queryBridgeID][attestation.requestCID];

        if (proposals.stake[attestation.responseCID].totalStake.attestationStake == 0) {
            console.log("proposal count++");
            proposals.proposalCount = proposals.proposalCount + 1;

            uint16 blockHashOffset = queryBridges[queryBridgeID].blockHashOffset;
            bytes32 queryBlockHash = _bytes32FromStringWithOffset(query, blockHashOffset+2); // todo: why +2?
            require(pinnedBlocks[queryBlockHash] > 0, "block hash unpinned");
        }

        // update stake values
        proposals.stake[attestation.responseCID].accountStake[attestationIndexer].attestationStake = indexerStake;
        proposals.stake[attestation.responseCID].totalStake.attestationStake = proposals.stake[attestation.responseCID].totalStake.attestationStake + indexerStake;
        proposals.totalStake.attestationStake = proposals.totalStake.attestationStake + indexerStake;

        // save entire query and response strings for testing executeProposal() later
        test_queries.push(query);
        test_requestCIDs.push(attestation.requestCID);
        test_queryResponses.push(response);

        console.log("submitted with requestCID: ");
        console.logBytes32(attestation.requestCID);
    }

    function executeProposal(
        string calldata query,
        bytes32 requestCID,     // todo: remove once we solve (query -> requestCID) mystery
        string calldata response,
        bytes32 queryBridgeID
    ) public {
        uint16 blockHashOffset = queryBridges[queryBridgeID].blockHashOffset;
        bytes32 queryBlockHash = _bytes32FromStringWithOffset(query, blockHashOffset+2); // todo: why +2?
        bytes32 queryTemplateHash = queryBridges[queryBridgeID].queryTemplate;
        bytes32 subgraphDeploymentID = queryBridges[queryBridgeID].subgraphDeploymentID;
        uint8 proposalFreezePeriod = queryBridges[queryBridgeID].proposalFreezePeriod;
        uint8 minimumSlashableGRT = queryBridges[queryBridgeID].minimumSlashableGRT;
        uint16 responseDataOffset = queryBridges[queryBridgeID].responseDataOffset;

        console.logBytes32(queryBlockHash);
        require(pinnedBlocks[queryBlockHash] + proposalFreezePeriod <= block.number, "proposal still frozen");

        bytes32 trimmedQueryHash = queryBridges[queryBridgeID].queryTemplate; // todo: why +2?
        console.log("query bridge ID called:::");
        console.logBytes32(trimmedQueryHash);
        console.logBytes32(subgraphDeploymentID);
        console.logBytes32(queryBridgeID);

        QueryBridgeProposals storage proposals = queryBridgeProposals[queryBridgeID][requestCID];
        require(proposals.proposalCount == 1, "proposalCount must be 1");
        bytes32 responseCID = keccak256(abi.encodePacked(response));
        
        require(proposals.stake[responseCID].totalStake.attestationStake > minimumSlashableGRT, "not enough stake");

        dataStreams[queryBridgeID][queryBlockHash] = _bytes32FromStringWithOffset(response, responseDataOffset);

        console.logBytes32(queryBlockHash);
        test_dataStreamIDs.push(queryBridgeID);
    }

    function _queryAndResponseMatchAttestation(
        string calldata query, 
        string calldata response, 
        IDisputeManager.Attestation memory attestation
    ) public returns (bool) {
        // todo: figure out why keccak256(query) doesn't match attestation.requestCID
        // require(attestation.requestCID == keccak256(abi.encodePacked(query)), "query does not match attestation requestCID");
        return (attestation.responseCID == keccak256(abi.encodePacked(response)));
    }

    function _bytes32FromStringWithOffset(string calldata fullString, uint16 dataOffset) public view returns (bytes32) {
        string memory blockHashSlice = string(fullString[
            dataOffset : dataOffset+64
        ]);
        console.log(fullString);
        console.log(blockHashSlice);
        return _bytes32FromHex(blockHashSlice);
    }

    // Convert an hexadecimal character to raw byte
    function _fromHexChar(uint8 c) public pure returns (uint8) {
        if (bytes1(c) >= bytes1('0') && bytes1(c) <= bytes1('9')) {
            return c - uint8(bytes1('0'));
        }
        if (bytes1(c) >= bytes1('a') && bytes1(c) <= bytes1('f')) {
            return 10 + c - uint8(bytes1('a'));
        }
    }

    // Convert hexadecimal string to raw bytes32
    function _bytes32FromHex(string memory s) public pure returns (bytes32 result) {
        bytes memory ss = bytes(s);
        require(ss.length == 64, "length of hex string must be 64");
        bytes memory bytesResult = new bytes(32);
        for (uint i=0; i<ss.length/2; ++i) {
            bytesResult[i] = bytes1(_fromHexChar(uint8(ss[2*i])) * 16 + _fromHexChar(uint8(ss[2*i+1])));
        }

        assembly {
            result := mload(add(bytesResult, 32))
        }
    }

    /**
     * @dev Parse the bytes attestation into a struct from `_data`.
     * @return Attestation struct
     */
    function _parseAttestation(bytes memory _data) public view returns (IDisputeManager.Attestation memory) {
        // Check attestation data length
        require(_data.length == ATTESTATION_SIZE_BYTES, "Attestation must be 161 bytes long");

        // Decode receipt
        (bytes32 requestCID, bytes32 responseCID, bytes32 subgraphDeploymentID) = abi.decode(
            _data,
            (bytes32, bytes32, bytes32)
        );

        // Decode signature
        // Signature is expected to be in the order defined in the Attestation struct
        bytes32 r = _toBytes32(_data, SIG_R_OFFSET);
        bytes32 s = _toBytes32(_data, SIG_S_OFFSET);
        uint8 v = _toUint8(_data, SIG_V_OFFSET);

        return IDisputeManager.Attestation(requestCID, responseCID, subgraphDeploymentID, r, s, v);
    }

    /**
     * @dev Parse a uint8 from `_bytes` starting at offset `_start`.
     * @return uint8 value
     */
    function _toUint8(bytes memory _bytes, uint256 _start) private pure returns (uint8) {
        require(_bytes.length >= (_start + UINT8_BYTE_LENGTH), "Bytes: out of bounds");
        uint8 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x1), _start))
        }

        return tempUint;
    }

    /**
     * @dev Parse a bytes32 from `_bytes` starting at offset `_start`.
     * @return bytes32 value
     */
    function _toBytes32(bytes memory _bytes, uint256 _start) private pure returns (bytes32) {
        require(_bytes.length >= (_start + BYTES32_BYTE_LENGTH), "Bytes: out of bounds");
        bytes32 tempBytes32;

        assembly {
            tempBytes32 := mload(add(add(_bytes, 0x20), _start))
        }

        return tempBytes32;
    }

    // Attestation size is the sum of the receipt (96) + signature (65)
    uint256 private constant ATTESTATION_SIZE_BYTES = RECEIPT_SIZE_BYTES + SIG_SIZE_BYTES;
    uint256 private constant RECEIPT_SIZE_BYTES = 96;

    uint256 private constant SIG_R_LENGTH = 32;
    uint256 private constant SIG_S_LENGTH = 32;
    uint256 private constant SIG_V_LENGTH = 1;
    uint256 private constant SIG_R_OFFSET = RECEIPT_SIZE_BYTES;
    uint256 private constant SIG_S_OFFSET = RECEIPT_SIZE_BYTES + SIG_R_LENGTH;
    uint256 private constant SIG_V_OFFSET = RECEIPT_SIZE_BYTES + SIG_R_LENGTH + SIG_S_LENGTH;
    uint256 private constant SIG_SIZE_BYTES = SIG_R_LENGTH + SIG_S_LENGTH + SIG_V_LENGTH;
        
    uint256 private constant UINT8_BYTE_LENGTH = 1;
    uint256 private constant BYTES32_BYTE_LENGTH = 32;

    uint256 MAX_UINT_256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
}