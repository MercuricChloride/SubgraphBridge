pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT

import "./SubgraphBridgeHelpers.sol";

interface ISubgraphBridge {
    function createQueryBridge(SubgraphBridgeHelpers.QueryBridge memory queryBridge) external;

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