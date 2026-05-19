// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BondNFT} from "../src/BondNFT.sol";
import {HumanBond} from "../src/HumanBond.sol";
import {MilestoneNFT} from "../src/MilestoneNFT.sol";
import {TimeToken} from "../src/TimeToken.sol";

/// @title Deploy Script for HumanBond Protocol
/// @notice Deploys TimeToken, BondNFT, MilestoneNFT and HumanBond logic contract, sets up linkage, and prints addresses.
contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy contract and tokens
        BondNFT bondNft = new BondNFT();
        MilestoneNFT milestoneNft = new MilestoneNFT();
        TimeToken timeToken = new TimeToken();
        address worldIdRouterReal = 0x17B354dD2595411ff79041f930e491A4Df39A278; // World ID Router mainnet address

        //Set milestones metadata URIs BEFORE ownership transfer
        milestoneNft.setMilestoneURI(1, "ipfs://QmPAVmWBuJnNgrGrAp34CqTa13VfKkEZkZak8d6E4MJio8");
        milestoneNft.setMilestoneURI(2, "ipfs://QmPTuKXg64EaeyreUFe4PJ1istspMd4G2oe2ArRYrtBGYn");

        // Compute external nullifiers and app ID
        string memory appId = "app_bfc3261816aeadc589f9c6f80a98f5df";
        string memory actionPropose = "propose-bond";
        string memory actionAccept = "accept-bond";

        //Deploy HumanBond main contract
        HumanBond humanBond = new HumanBond(
            worldIdRouterReal, // replace w/ chosen network WORLD ID ROUTER
            address(bondNft),
            address(timeToken),
            address(milestoneNft),
            appId,
            actionPropose,
            actionAccept,
            1 days,
            365 days,
            30 days
        );

        //Link contracts
        milestoneNft.setHumanBondContract(address(humanBond)); //Link MilestoneNFT to HumanBond
        bondNft.setHumanBondContract(address(humanBond));
        timeToken.setMinter(address(humanBond), true);

        vm.stopBroadcast();

        // Logs
        console.log("BondNFT deployed at:", address(bondNft));
        console.log("MilestoneNFT deployed at:", address(milestoneNft));
        console.log("HumanBond deployed at:", address(humanBond));
        console.log("Time Token deployed at:", address(timeToken));
        console.log("Deployment complete!");
    }
}
