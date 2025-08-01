// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    DeployDSC public deployer;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    address public deployerKey;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
    }

    //////////////
    // Constructor Tests
    //////////////
    address[] tokens;
    address[] priceFeeds;

    function testRevertIfTokenLengthDoesNotMatchFeedLength() public {
        tokens.push(weth);
        tokens.push(wbtc);
        priceFeeds.push(ethUsdPriceFeed);
        // Intentionally not adding a price feed for wbtc to trigger the revert
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    /////////////
    // Price Tests
    /////////////
    function testGetUsdValue() public view {
        uint256 wethAmount = 15 ether;
        uint256 expectedUsd = 30000 ether;
        uint256 actualUsd = dsce.getUsdValue(weth, wethAmount);
        assertEq(actualUsd, expectedUsd, "USD value calculation is incorrect");
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedTokenAmount = 0.05 ether; // Assuming 1 ETH = 2000 USD
        uint256 actualTokenAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualTokenAmount, expectedTokenAmount, "Token amount calculation is incorrect");
    }

    //////////////
    // Collateral Tests
    //////////////
    function testRevertWhenDepositZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("Random Token", "RAN", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalCollateralValueInUsd, uint256 totalDscMinted) = dsce.getAccountInformation(USER);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount, "Total collateral value in USD is incorrect");
        assertEq(totalDscMinted, 0, "Total DSC minted should be zero after deposit");

        vm.stopPrank();
    }
}
