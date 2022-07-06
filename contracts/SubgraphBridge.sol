// SPDX-License-Identifier: MIT

import "hardhat/console.sol";
import "./dependencies/TheGraph/IController.sol";
import "./dependencies/TheGraph/IStaking.sol";
import "./dependencies/TheGraph/IDisputeManager.sol";

pragma solidity ^0.8.0;



contract SubgraphBridge {

    // address public theGraphController;
    address public theGraphStaking;
    address public theGraphDisputeManager;

    // query string up until block hash
    bytes32 constant QUERY_START_HASH = 0x4e9480015d2cc684e9324eb95a72b7aac0951dc6ae183895eaa20bddbcca8942;
    // query string following block hash
    bytes32 constant QUERY_END_HASH = 0x038327e0981c8b6b24d870571a1a4c5547fcccc9e6191b5cbf1a798bc1ea95e9;

    // undisputed proposals can only be executed after this many blocks
    uint256 constant PROPOSAL_FREEZE_PERIOD = 100;

    // disputes can only be resolved when slashableStake * multiplier > total slashableStake
    uint256 constant DISPUTE_RESOLUTION_MULTIPLIER = 3;
    // disputes can only be resolved after this many blocks
    uint256 constant DISPUTE_RESOLUTION_LOCK = 100;

    // organizes all proposals for a given block
    struct PinnedBlockProposals {
        // proposed state hash -> stake
        mapping (bytes32 => BridgeStake) stake;
        BridgeStakeTokens totalStake;
        uint256 proposalCount;
        uint256 pinnedBlockNumber;
    }

    struct BridgeStake {
        BridgeStakeTokens totalStake;
        mapping (address => BridgeStakeTokens) accountStake;
    }

    struct BridgeStakeTokens {
        uint256 attestationStake;   // Slashable GRT staked by indexers via the staking contract
        uint256 tokenStake;         // GRT staked by oracles through Subgraph Bridge contract
    }

    // {pinnedBlockHash} -> {PinnedBlockProposals}
    mapping (bytes32 => PinnedBlockProposals) public bridgeProposals;
    // {pinnedBlockHash} -> {block number}
    mapping (bytes32 => uint256) public bridgeConflictResolutionBlock;
    uint256 public pinnedBlockNumber;   // block number when last proposal was executed
    bytes32 public pinnedBlockState;    // state of the rollup at pinnedBlockNumber

    constructor(address staking, address disputeManager) {
        theGraphStaking = staking;
        theGraphDisputeManager = disputeManager;
    }

    function submitProposal(
        uint256 blockNumber,
        string calldata query, 
        string calldata response,
        bytes calldata attestationData
    ) public {

        // ensure the block hash we are pinning exists in chain history
        bytes32 queryBlockHash = blockHashFromQuery(query);
        PinnedBlockProposals storage proposals = bridgeProposals[queryBlockHash];
        if(proposals.totalStake.attestationStake == 0) {
            require(queryBlockHash == blockhash(blockNumber), "block hash not found in chain history");
        }

        IDisputeManager.Attestation memory attestation = _parseAttestation(attestationData);

        // require a valid attestation signed by an indexer.
        address attestationIndexer = IDisputeManager(theGraphDisputeManager).getAttestationIndexer(attestation);
        require(queryAndResponseMatchAttestation(query, response, attestation), "query/response doesn't match attestation");

        // get indexer's slashable stake from staking contract
        uint256 indexerStake = IStaking(theGraphStaking).getIndexerStakedTokens(attestationIndexer);
        require(indexerStake > 0, "indexer doesn't have enough stake");
        bytes32 stateHash = stateHashFromResponse(response);

        // enforce one attestation per indexer
        require(proposals.stake[stateHash].accountStake[attestationIndexer].attestationStake == 0, "attestation already exists for indexer");

        if (proposals.stake[stateHash].totalStake.attestationStake == 0) {
            proposals.proposalCount = proposals.proposalCount + 1;
        }

        if (proposals.proposalCount == 1) {
            proposals.pinnedBlockNumber = blockNumber;
        }
        else if (proposals.proposalCount > 1 && bridgeConflictResolutionBlock[queryBlockHash] == 0) {
            // kicks off arbitration window and invalidates entire proposal
            bridgeConflictResolutionBlock[queryBlockHash] = blockNumber + PROPOSAL_FREEZE_PERIOD;
        }

        // update stake values
        proposals.stake[stateHash].accountStake[attestationIndexer].attestationStake = indexerStake;
        proposals.stake[stateHash].totalStake.attestationStake = proposals.stake[stateHash].totalStake.attestationStake + indexerStake;
        proposals.totalStake.attestationStake = indexerStake;

        console.log("Saved Proposal with ID: ");
        console.logBytes32(queryBlockHash);
    }

    function executeProposal(
        bytes32 pinnedBlockHash,
        bytes32 stateHash
    ) public {
        PinnedBlockProposals storage proposals = bridgeProposals[pinnedBlockHash];
        require(proposals.proposalCount == 1, "proposalCount must be 1");
        require(proposals.stake[stateHash].totalStake.attestationStake > 0, "invalid stateHash");
        require(proposals.pinnedBlockNumber + PROPOSAL_FREEZE_PERIOD > block.number, "proposal still in challenge window");
        require(proposals.pinnedBlockNumber > pinnedBlockNumber, "block already synced");
        pinnedBlockNumber = proposals.pinnedBlockNumber;
        pinnedBlockState = stateHash;
    }

    function resolveDispute(
        bytes32 pinnedBlockHash,
        bytes32 stateHash
    ) public {
        uint256 resolutionBlock = bridgeConflictResolutionBlock[pinnedBlockHash];
        require(resolutionBlock > 0, "no dispute");
        require(resolutionBlock < block.number, "proposal still in challenge window");

        PinnedBlockProposals storage proposals = bridgeProposals[pinnedBlockHash];
        uint256 proposalStake = proposals.stake[stateHash].totalStake.attestationStake;
        uint256 totalStake = proposals.totalStake.attestationStake;
        // todo: add external GRT staking into arbitration
        require(proposalStake * DISPUTE_RESOLUTION_MULTIPLIER > totalStake, "not enough stake");
        bridgeConflictResolutionBlock[pinnedBlockHash] = MAX_UINT_256;
    }

    function queryAndResponseMatchAttestation(
        string calldata query, 
        string calldata response, 
        IDisputeManager.Attestation memory attestation
    ) public returns (bool) {
        // todo: figure out why hashing the query doesn't match attestation.requestCID
        // require(attestation.requestCID == keccak256(abi.encodePacked(query)), "query does not match attestation requestCID");
        return (attestation.responseCID == keccak256(abi.encodePacked(response)));
    }


    // example query: "{earnedBadges(first:1,orderBy:blockAwarded,orderDirection:desc,block:{hash:\"0x018dbfdbc6cfcbc380b164b779e8297a01faf5903ba89e06950c900cd767cde3\"}){transactionHash}}"
    function blockHashFromQuery(string calldata query) public view returns (bytes32) {
        require((bytes(query)).length == 163, "query length must be 163");
        console.log(query[:78]);
        console.logBytes32(keccak256(abi.encodePacked(string(query[142:]))));

        // verify this is the Bridge query.
        require(keccak256(abi.encodePacked(string(query[:78]))) == QUERY_START_HASH, "query start doesn't match");
        require(keccak256(abi.encodePacked(string(query[142:]))) == QUERY_END_HASH, "query end doesn't match");

        string memory blockHashSlice = string(query[78:142]);
        console.log(blockHashSlice);
        return bytes32FromHex(blockHashSlice);
    }

    function stateHashFromResponse(string calldata response) public view returns (bytes32) {
        console.log(bytes(response).length);
        console.log(response[47:111]);
        string memory stateHashSlice = string(response[47:111]);
        return bytes32FromHex(stateHashSlice);
    }

    // Convert an hexadecimal character to raw byte
    function fromHexChar(uint8 c) public pure returns (uint8) {
        if (bytes1(c) >= bytes1('0') && bytes1(c) <= bytes1('9')) {
            return c - uint8(bytes1('0'));
        }
        if (bytes1(c) >= bytes1('a') && bytes1(c) <= bytes1('f')) {
            return 10 + c - uint8(bytes1('a'));
        }
    }

    // Convert hexadecimal string to raw bytes32
    function bytes32FromHex(string memory s) public pure returns (bytes32 result) {
        bytes memory ss = bytes(s);
        require(ss.length == 64, "length of hex string must be 64");
        bytes memory bytesResult = new bytes(32);
        for (uint i=0; i<ss.length/2; ++i) {
            bytesResult[i] = bytes1(fromHexChar(uint8(ss[2*i])) * 16 + fromHexChar(uint8(ss[2*i+1])));
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