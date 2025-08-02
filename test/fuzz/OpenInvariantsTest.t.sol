// // SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract InvariantsTest is StdInvariant, Test {
//     DSCEngine public dsce;
//     DecentralizedStableCoin public dsc;
//     HelperConfig public helperConfig;
//     address public weth;
//     address public wbtc;

//     function setUp() external {
//         DeployDSC deployer = new DeployDSC();
//         (dsc, dsce, helperConfig) = deployer.run();
//         (,, weth, wbtc,) = helperConfig.activeNetworkConfig();

//         targetContract(address(dsce));
//         // targetContract(address(ethUsdPriceFeed));// Why can't we just do this?
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));

//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));
//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         assertGe(
//             wethValue + wbtcValue,
//             totalSupply,
//             "Total value of collateral must be greater than or equal to total supply of DSC"
//         );
//     }
// }
