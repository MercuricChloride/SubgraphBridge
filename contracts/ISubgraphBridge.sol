pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT

interface ISubgraphBridge {

    enum BridgeDataType {
        ADDRESS,
        BYTES32,
        UINT
        // todo: string
    }

    struct QueryBridge {
        bytes32 queryTemplate;                      // hash of query stripped of all query variables
        // bytes32 subgraphDeploymentID;               // subgraph being queried
        uint16 responseDataOffset;                  // index where the data starts in the response string
        uint16 blockHashOffset;                     // where the pinned block hash starts in the query string
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

    function createQueryBridge(QueryBridge memory queryBridge) external;

    function submitQueryBridgeProposal(
        uint256 blockNumber,
        string calldata query,
        string calldata response,
        bytes32 queryBridgeID,
        bytes calldata attestationData
    ) external;

    function executeProposal(
        string calldata query,
        bytes32 requestCID,
        string calldata response,
        bytes32 queryBridgeID
    ) external;
}