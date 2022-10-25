// SPDX-License-Identifier: MIT

import "hardhat/console.sol";
import "./dependencies/TheGraph/IController.sol";
import "./dependencies/TheGraph/IStaking.sol";
import "./dependencies/TheGraph/IDisputeManager.sol";

pragma solidity ^0.8.0;



// THIS IS THE OLD CONTRACT
contract OldSubgraphBridge {

    enum BridgeDataType {
        ADDRESS,
        BYTES32,
        UINT
        // todo: string
    }

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
        BridgeDataType responseDataType;            // data type to be extracted from graphQL response string
        uint16[2] queryVariables;                   // type stored in first byte, location in last
        
        uint8 proposalFreezePeriod;                 // undisputed queries can only be executed after this many blocks
        uint8 minimumSlashableGRT;                  // minimum slashable GRT staked by indexers in order for undisputed proposal to pass

        // dispute handling config
        uint8 minimumExternalStake;                 // minimum external tokens staked in order for undisputed proposal to pass
        uint8 disputeResolutionWindow;              // how many blocks it takes for disputes to be settled (0 indicates no dispute resolution)
        uint8 resolutionThresholdSlashableGRT;      // (30-99) percent of slashable GRT required for dispute resolution
        uint8 resolutionThresholdExternalStake;     // (30-99) percentage of external stake required for dispute resolution
        address stakingToken;                       // erc20 token for external staking
    }

    // NOTE: Should be pure
    function _queryBridgeID(QueryBridge memory queryBridge) public pure returns (bytes32) {
        return keccak256(abi.encode(queryBridge));
    }


    // returns keccak of query string stripped of Query Variables and block hash
    function _generateQueryTemplateHash(
        string calldata query,
        uint256 blockHashOffset,
        uint16[2] memory queryVariables
    ) public view returns (bytes32) {

        uint8 qv0Idx = uint8(queryVariables[0] >> 8);
        uint8 qv0Length = _lengthForQueryVariable(qv0Idx, BridgeDataType(uint8(queryVariables[0])), query);
        uint8 qv1Idx = uint8(queryVariables[1] >> 8) + qv0Idx + qv0Length;
        uint8 qv1Length = _lengthForQueryVariable(qv1Idx, BridgeDataType(uint8(queryVariables[1])), query);

        console.log("qv0idx qv0length qv1idx qv1length");
        console.log(qv0Idx);    // index where qv1 starts
        console.log(qv0Length);
        console.log(qv1Idx);    // number of characters between end of qv0 and start of qv1
        console.log(qv1Length);

        bytes memory strippedQTemplate = bytes.concat(
            bytes(query)[:blockHashOffset],
            bytes(query)[blockHashOffset+66:qv0Idx]
        );

        if (qv1Idx == 0) {
            strippedQTemplate = bytes.concat(
                strippedQTemplate,
                bytes(query)[qv0Idx+qv0Length:]
            );
        } else {
            strippedQTemplate = bytes.concat(
                strippedQTemplate,
                bytes(query)[qv0Idx+qv0Length:qv1Idx],
                bytes(query)[qv1Idx+qv1Length:]
            );
        }


        console.log("stripped query template");
        console.log(string(strippedQTemplate));

        return keccak256(abi.encode(strippedQTemplate));
    }

    function _lengthForQueryVariable(
        uint8 qVariableIdx,
        BridgeDataType qVariableType,
        string calldata query
    ) public view returns (uint8) {
        if (qVariableType == BridgeDataType.ADDRESS) {
            return 42;
        } 
        else if (qVariableType == BridgeDataType.BYTES32) {
            return 66;
        }
        else {  // uint, string
            return _dynamicLengthForQueryVariable(qVariableIdx, bytes(query));
        }
    }

    function _dynamicLengthForQueryVariable(
        uint8 qVariableIdx,
        bytes calldata query
    ) public view returns (uint8) {

        uint8 length = 0;
        bool shouldEscape = false;
        while (!shouldEscape) {
            bytes1 char = query[qVariableIdx + length];
            console.logBytes1(char);
            shouldEscape = (char == 0x7D || char == 0x2C || char == 0x29 || char == 0x22);     // ,})"
            if (!shouldEscape) {
                length += 1;
            }
        }

        return length;
    }

    // {block hash} -> {block number}
    mapping (bytes32 => uint256) public pinnedBlocks;

    // {QueryBridgeID} -> {QueryBridge}
    mapping (bytes32 => QueryBridge) public queryBridges;

    // {QueryBridgeID} -> {attestation.requestCID} -> {QueryBridgeProposals}
    mapping (bytes32 => mapping (bytes32 => QueryBridgeProposals)) public queryBridgeProposals;

    // not yet implemented
    // {QueryBridgeID} -> {attestation.requestCID} -> {block number}
    mapping (bytes32 => mapping (bytes32 => uint256)) public bridgeConflictResolutionBlock;

    // {QueryBridgeID} -> {requestCID} -> {responseData}
    mapping (bytes32 => mapping (bytes32 => uint256)) public dataStreams;

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

    // NOTE: Should be view
    function hashQueryTemplate(string memory queryTemplate) public view {
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

    // NOTE: Should be view
    function _queryMatchesBridge(
        string calldata query,
        bytes32 queryBridgeID
    ) public view returns (bool) {
        QueryBridge memory bridge = queryBridges[queryBridgeID];
        return (_generateQueryTemplateHash(query, bridge.blockHashOffset, bridge.queryVariables) == bridge.queryTemplate);
    }

    function submitQueryBridgeProposal(
        string calldata query,
        string calldata response,
        bytes32 queryBridgeID,
        bytes calldata attestationData
    ) public {
        require(queryBridges[queryBridgeID].blockHashOffset > 0, "query bridge doesn't exist");
        require(_queryMatchesBridge(query, queryBridgeID), "query doesn't fit template");
        
        IDisputeManager.Attestation memory attestation = _parseAttestation(attestationData);
        require(_queryAndResponseMatchAttestation(response, attestation), "query/response != attestation");

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
        uint16 blockHashOffset = queryBridges[queryBridgeID].blockHashOffset+2;
        bytes32 queryBlockHash = _bytes32FromStringWithOffset(query, blockHashOffset); // todo: why +2?
        // bytes32 queryTemplateHash = queryBridges[queryBridgeID].queryTemplate;
        // bytes32 subgraphDeploymentID = queryBridges[queryBridgeID].subgraphDeploymentID;
        uint8 proposalFreezePeriod = queryBridges[queryBridgeID].proposalFreezePeriod;
        uint8 minimumSlashableGRT = queryBridges[queryBridgeID].minimumSlashableGRT;
        // uint16 responseDataOffset = queryBridges[queryBridgeID].responseDataOffset;

        console.logBytes32(queryBlockHash);
        require(pinnedBlocks[queryBlockHash] + proposalFreezePeriod <= block.number, "proposal still frozen");
        require(_queryMatchesBridge(query, queryBridgeID), "query doesn't fit template");

        QueryBridgeProposals storage proposals = queryBridgeProposals[queryBridgeID][requestCID];
        require(proposals.proposalCount == 1, "proposalCount must be 1");
        bytes32 responseCID = keccak256(abi.encodePacked(response));
        
        require(proposals.stake[responseCID].totalStake.attestationStake > minimumSlashableGRT, "not enough stake");

        _extractData(queryBridgeID, requestCID, response);

        // test_dataStreamIDs.push(queryBridgeID);
    }

    function _extractData(bytes32 queryBridgeID, bytes32 requestCID, string calldata response) private {
        uint responseT = uint(queryBridges[queryBridgeID].responseDataType);
        console.log(responseT);
        if (queryBridges[queryBridgeID].responseDataType == BridgeDataType.UINT) {
            console.log("it's a uint response");
            dataStreams[queryBridgeID][requestCID] = _uintFromString(response, queryBridges[queryBridgeID].responseDataOffset);
            string memory s = response[queryBridges[queryBridgeID].responseDataOffset:];
            console.log(s);
        }
    }

    function _queryAndResponseMatchAttestation(
        // string calldata query, 
        string calldata response, 
        IDisputeManager.Attestation memory attestation
    ) public pure returns (bool) {
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

    function _uintFromString(string calldata str, uint256 offset) public view returns (uint256) {
        (uint256 val,) = _uintFromByteString(bytes(str), offset);
        string memory s = str[offset:];
        console.log(s);
        return val;
    }

    // takes a full query string or response string and extracts a uint of unknown length beginning at the specified index
    function _uintFromByteString(
        bytes memory bString,
        uint256 offset
    ) public view returns(uint256 value, uint256 depth) {

        bytes1 char = bString[offset];
        bool isEscapeChar = (char == 0x7D || char == 0x2C || char == 0x22);     // ,}"
        if (isEscapeChar) {
            return (0, 0);
        }

        bool isDigit = (uint8(char) >= 48) && (uint8(char) <= 57);              // 0-9
        require(isDigit, "invalid char");

        (uint256 trailingVal, uint256 trailingDepth) = _uintFromByteString(bString, offset + 1);
        return (trailingVal + (uint8(char) - 48) * 10**(trailingDepth), trailingDepth + 1);
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
    function _parseAttestation(bytes memory _data) public pure returns (IDisputeManager.Attestation memory) {
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