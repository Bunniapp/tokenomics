// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

///@notice This cheat codes interface is named _CheatCodes so you can use the CheatCodes interface in other testing files without errors
interface _CheatCodes {
    function ffi(string[] calldata) external returns (bytes memory);
}

contract VyperDeployer {
    address constant HEVM_ADDRESS = address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Initializes cheat codes in order to use ffi to compile Vyper contracts
    _CheatCodes cheatCodes = _CheatCodes(HEVM_ADDRESS);

    ///@notice Compiles a Vyper contract and returns the address that the contract was deployeod to
    ///@notice If deployment fails, an error will be thrown
    ///@param fileName - The file name of the Vyper contract. For example, the file name for "SimpleStore.vy" is "SimpleStore"
    ///@return deployedAddress - The address that the contract was deployed to

    function deployContract(string memory fileName) public returns (address) {
        ///@notice create a list of strings with the commands necessary to compile Vyper contracts
        string[] memory cmds = new string[](2);
        cmds[0] = "vyper";
        cmds[1] = string.concat("vyper_contracts/", fileName, ".vy");

        ///@notice compile the Vyper contract and return the bytecode
        bytes memory bytecode = cheatCodes.ffi(cmds);

        ///@notice deploy the bytecode with the create instruction
        address deployedAddress;
        assembly {
            deployedAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        ///@notice check that the deployment was successful
        require(deployedAddress != address(0), string.concat("VyperDeployer could not deploy contract: ", fileName));

        ///@notice return the address that the contract was deployed to
        return deployedAddress;
    }

    ///@notice Compiles a Vyper contract with constructor arguments and returns the address that the contract was deployeod to
    ///@notice If deployment fails, an error will be thrown
    ///@param fileName - The file name of the Vyper contract. For example, the file name for "SimpleStore.vy" is "SimpleStore"
    ///@return deployedAddress - The address that the contract was deployed to
    function deployContract(string memory fileName, bytes memory args) public returns (address) {
        ///@notice create a list of strings with the commands necessary to compile Vyper contracts
        string[] memory cmds = new string[](2);
        cmds[0] = "vyper";
        cmds[1] = string.concat("vyper_contracts/", fileName, ".vy");

        ///@notice compile the Vyper contract and return the bytecode
        bytes memory _bytecode = cheatCodes.ffi(cmds);

        //add args to the deployment bytecode
        bytes memory bytecode = abi.encodePacked(_bytecode, args);

        ///@notice deploy the bytecode with the create instruction
        address deployedAddress;
        assembly {
            deployedAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        ///@notice check that the deployment was successful
        require(deployedAddress != address(0), string.concat("VyperDeployer could not deploy contract: ", fileName));

        ///@notice return the address that the contract was deployed to
        return deployedAddress;
    }

    function compileContract(string memory fileName) public returns (bytes memory bytecode) {
        ///@notice create a list of strings with the commands necessary to compile Vyper contracts
        string[] memory cmds = new string[](2);
        cmds[0] = "vyper";
        cmds[1] = string.concat("vyper_contracts/", fileName, ".vy");

        ///@notice compile the Vyper contract and return the bytecode
        bytecode = cheatCodes.ffi(cmds);
    }
}
