// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 50;
    uint256 private constant HEALTH_FACTOR_LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1; // 1.0 in 18 decimals

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposits;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 amount);

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

    /*
        * @param collateralToken The address of the collateral token
        * @param amount The amount of collateral to deposit
        */
    function depositCollateral(address collateralToken, uint256 amount)
        external
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

    /**
     * @notice Mints DSC to the caller's address.
     * @param amountDSCToMint The amount of DSC to mint.
     * @notice The caller must have more collateral deposited than the value of DSC they are trying to mint.
     */
    function mintDSC(uint256 amountDSCToMint) external moreThanZero(amountDSCToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    ///////////////////////////////////
    /// Private and Internal Functions
    ///////////////////////////////////

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
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / HEALTH_FACTOR_LIQUIDATION_PRECISION;
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

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address collateralToken = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposits[user][collateralToken];
            if (collateralAmount > 0) {
                uint256 collateralValueInUsd = getUsdValue(collateralToken, collateralAmount);
                totalCollateralValueInUsd += collateralValueInUsd;
            }
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (amount * uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION; // Assuming price is in USD
    }
}
