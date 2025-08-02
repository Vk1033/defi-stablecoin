// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author vk1033
 *
 * @notice This contract will handle the logic for minting and burning the Decentralized Stable Coin (DSC).
 * @notice It will also manage collateral deposits and withdrawals.
 *
 * Our DSC should be always overcollateralized.
 *
 * This stablecoin is designed to be algorithmic and pegged to USD.
 * Similar to DAI, if DAI had no governance, no fees and was backed by wETH and wBTC.
 */
contract DSCEngine is ReentrancyGuard {
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__CollateralDepositFailed();
    error DSCEngine__HealthFactorBroken();
    error DSCEngine__MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1.0 in 18 decimals
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposits;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed collateralToken, uint256 amount
    );

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address token = tokenAddresses[i];
            address priceFeed = priceFeedAddresses[i];
            s_priceFeeds[token] = priceFeed;
            s_collateralTokens.push(token);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////
    // External Functions
    //////////////////

    /**
     *
     * @param collateralToken The address of the collateral token
     * @param amount The amount of collateral to deposit
     * @param amountDSCToMint The amount of DSC to mint
     * @notice This function allows users to deposit collateral and mint DSC in a single transaction.
     */
    function depositCollateralAndMintDSC(address collateralToken, uint256 amount, uint256 amountDSCToMint)
        external
        moreThanZero(amount)
        isAllowedToken(collateralToken)
        nonReentrant
    {
        depositCollateral(collateralToken, amount);
        mintDSC(amountDSCToMint);
    }

    /*
        * @param collateralToken The address of the collateral token
        * @param amount The amount of collateral to deposit
        */
    function depositCollateral(address collateralToken, uint256 amount)
        public
        moreThanZero(amount)
        isAllowedToken(collateralToken)
        nonReentrant
    {
        s_collateralDeposits[msg.sender][collateralToken] += amount;
        emit CollateralDeposited(msg.sender, collateralToken, amount);
        bool success = IERC20(collateralToken).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__CollateralDepositFailed();
        }
    }

    function redeemCollateral(address collateralToken, uint256 amount) public moreThanZero(amount) nonReentrant {
        _redeemCollateral(collateralToken, amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function allows users to redeem their collateral for DSC.
     * @param collateralToken The address of the collateral token
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice The caller must have enough collateral deposited and must maintain a healthy health factor.
     */
    function redeemCollateralForDSC(address collateralToken, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        redeemCollateral(collateralToken, amountCollateral);
        burnDSC(amountDscToBurn);
        // redeemCollateral already checks health factor
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mints DSC to the caller's address.
     * @param amountDSCToMint The amount of DSC to mint.
     * @notice The caller must have more collateral deposited than the value of DSC they are trying to mint.
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice This function allows a liquidator to liquidate a user's collateral if their health factor is below the minimum threshold.
     * @param collateral The address of the collateral token to liquidate.
     * @param user The address of the user whose collateral is being liquidated.
     * @param debtToCover The amount of DSC to burn in exchange for the collateral.
     * @notice If the user's health factor is above the minimum threshold, the function will revert.
     * @notice The liquidator will receive a bonus in collateral for covering the user's debt.
     * @notice The liquidator must cover the user's debt in DSC, and they will receive a bonus in collateral.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////
    /// Private and Internal Functions
    ///////////////////////////////////

    function _burnDSC(uint256 amountToBurn, address onBehalfOf, address dscFrom) private moreThanZero(amountToBurn) {
        s_dscMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _redeemCollateral(address collateralToken, uint256 amount, address from, address to)
        private
        moreThanZero(amount)
        isAllowedToken(collateralToken)
    {
        s_collateralDeposits[from][collateralToken] -= amount;
        emit CollateralRedeemed(from, to, collateralToken, amount);
        bool success = IERC20(collateralToken).transfer(to, amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice This function retrieves the total collateral value and total DSC minted for a user.
     * @param user The address of the user for whom to retrieve the information.
     * @return totalCollateralValueInUsd The total value of the user's collateral deposits.
     * @return totalDscMinted The total amount of DSC minted by the user.
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalDscMinted)
    {
        // Placeholder logic for calculating total collateral value and total DSC minted
        // This should iterate over the user's collateral deposits and calculate the total value
        // based on the price feeds.
        totalCollateralValueInUsd = getAccountCollateralValue(user);
        totalDscMinted = s_dscMinted[user];
    }

    /**
     * @param user The address of the user for whom to calculate the health factor.
     * @return The health factor of the user, which is a measure of their collateralization
     *         ratio. A health factor greater than 1 indicates that the user is overcolllateralized,
     *         while a health factor less than or equal to 1 indicates that the user is undercollateralized.
     * @notice The health factor is calculated based on the user's collateral deposits and the amount of DSC they have minted.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalCollateralValueInUsd, uint256 totalDscMinted) = _getAccountInformation(user);
        return _calculateHealthFactor(totalCollateralValueInUsd, totalDscMinted);
    }

    function _calculateHealthFactor(uint256 totalCollateralValueInUsd, uint256 totalDscMinted)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max; // No DSC minted, infinite health factor
        }
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken();
        }
    }

    ///////////////////////////////////
    /// Public and External View Functions
    ///////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposits[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (amount * uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION; // Assuming price is in USD
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalDscMinted)
    {
        return _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address collateralToken) external view returns (uint256) {
        return s_collateralDeposits[user][collateralToken];
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
