// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TransferRef
/// @notice Derives the on-chain settlement reference from a backend transfer id.
/// @dev The backend must compute the same value: keccak256(utf8("kimana:transfer:" + transferId)).
///      The domain prefix prevents collisions with other id spaces that may be hashed in the future.
library TransferRef {
    function fromTransferId(string memory transferId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("kimana:transfer:", transferId));
    }
}
