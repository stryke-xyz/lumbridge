// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {StakedSYK} from "../src/governance/StakedSYK.sol";

contract DeployStakedSYK is Script {
    address public constant SYK = 0x97C065EEd0309F182777BfFa41A9C0027c190DF1;
    address public constant ACCESS_MANAGER = 0x99fF939Ef399f5569d57868d43118e6586F574d9;

    function run() public returns (StakedSYK staking) {
        require(block.chainid == 4663, "run on Robinhood Chain");
        require(SYK.code.length > 0, "SYK not deployed");
        require(ACCESS_MANAGER.code.length > 0, "AccessManager not deployed");

        uint256 cooldown = vm.envOr("COOLDOWN_SECONDS", uint256(7 days));
        require(cooldown <= 7 days, "cooldown exceeds 7 days");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        staking = new StakedSYK(SYK, cooldown, ACCESS_MANAGER);
        vm.stopBroadcast();

        require(address(staking.syk()) == SYK, "incorrect SYK");
        require(staking.authority() == ACCESS_MANAGER, "incorrect authority");
        require(staking.cooldown() == cooldown, "incorrect cooldown");

        console.log("StakedSYK:", address(staking));
        console.log("SYK:", SYK);
        console.log("AccessManager:", ACCESS_MANAGER);
        console.log("Cooldown (seconds):", cooldown);
    }
}
