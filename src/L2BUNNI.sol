// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "./lib/XERC20.sol";

/// @title L2BUNNI
/// @notice L2 deployment of BUNNI that does not mint any initial tokens.
/// @author zefram.eth
contract L2BUNNI is XERC20 {
    uint256 public constant MAX_SUPPLY = 1e27; // 1 billion tokens

    error L2BUNNI_InvalidLength();

    constructor(
        address _initialOwner,
        uint256[] memory _minterLimits,
        uint256[] memory _burnerLimits,
        address[] memory _bridges
    ) XERC20(_initialOwner) {
        uint256 _bridgesLength = _bridges.length;
        if (_minterLimits.length != _bridgesLength || _burnerLimits.length != _bridgesLength) {
            revert L2BUNNI_InvalidLength();
        }

        for (uint256 i; i < _bridgesLength; ++i) {
            _setLimits(_bridges[i], _minterLimits[i], _burnerLimits[i]);
        }
    }

    function name() public pure override returns (string memory) {
        return "Bunni";
    }

    function symbol() public pure override returns (string memory) {
        return "BUNNI";
    }
}
