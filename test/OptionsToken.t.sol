// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {OptionsToken} from "../src/OptionsToken.sol";
import {BunniHookOracle} from "../src/oracles/BunniHookOracle.sol";
import {IBunniHook, PoolKey} from "../src/external/IBunniHook.sol";
import {IBunniHub} from "./interfaces/IBunniHub.sol";
import {TickMath} from "../src/lib/TickMath.sol";

contract OptionsTokenTest is Test {
    using TickMath for *;
    using FixedPointMathLib for *;

    uint16 constant ORACLE_MULTIPLIER = 5000; // 0.5
    uint32 constant ORACLE_SECS = 30 minutes;
    uint32 constant ORACLE_AGO = 2 minutes;
    uint128 constant ORACLE_MIN_PRICE = 1e6;
    uint256 constant ORACLE_MULTIPLIER_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

    uint24 internal constant FEE_MIN = 0.0001e6;
    uint24 internal constant FEE_MAX = 0.1e6;
    uint24 internal constant FEE_QUADRATIC_MULTIPLIER = 0.5e6;
    uint24 internal constant FEE_TWAP_SECONDS_AGO = 30 minutes;
    uint24 internal constant SURGE_FEE = 0.1e6;
    uint16 internal constant SURGE_HALFLIFE = 1 minutes;
    uint16 internal constant SURGE_AUTOSTART_TIME = 2 minutes;
    uint16 internal constant VAULT_SURGE_THRESHOLD_0 = 1e4; // 0.01% change in share price
    uint16 internal constant VAULT_SURGE_THRESHOLD_1 = 1e3; // 0.1% change in share price
    uint32 internal constant HOOK_FEE_MODIFIER = 0.1e6;
    uint32 internal constant REFERRAL_REWARD_MODIFIER = 0.1e6;
    uint16 internal constant REBALANCE_THRESHOLD = 100; // 1 / 100 = 1%
    uint16 internal constant REBALANCE_MAX_SLIPPAGE = 1; // 5%
    uint16 internal constant REBALANCE_TWAP_SECONDS_AGO = 1 hours;
    uint16 internal constant REBALANCE_ORDER_TTL = 10 minutes;
    uint32 internal constant ORACLE_MIN_INTERVAL = 1 hours;

    int24 internal constant TICK_SPACING = 100;
    int24 internal constant INITIAL_TICK = -9800;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    // sepolia deployments
    IBunniHub constant bunniHub = IBunniHub(0x9fcB8DbbB93F908f0ff2f9B425594A0511dd71c4);
    IBunniHook constant bunniHook = IBunniHook(0x56aafc3fF6B436Eb171615acb9fb723f025D1888);
    address constant carpetedDoubleGeometricLDF = 0xdAC2a807Fe819777Eb708CEC92d37B8f1914CE86;

    address owner;
    address treasury;

    OptionsToken optionsToken;
    BunniHookOracle oracle;
    ERC20Mock paymentToken;
    ERC20Mock underlyingToken;
    uint256 initialTwap;

    modifier onlyChain(string memory chain) {
        vm.assume(getChain(chain).chainId == block.chainid);
        _;
    }

    function setUp() public onlyChain("sepolia") {
        // set up accounts
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");

        // deploy tokens
        paymentToken = new ERC20Mock();
        underlyingToken = new ERC20Mock();

        // deploy Bunni pool
        (address currency0, address currency1) = address(paymentToken) < address(underlyingToken)
            ? (address(paymentToken), address(underlyingToken))
            : (address(underlyingToken), address(paymentToken));
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                uint8(0), // shiftMode
                int24(-10000), // minTick
                int16(10), // length0
                uint32(0.9e8), // alpha0
                uint32(1), // weight0
                int16(10), // length1
                uint32(1.11e8), // alpha1
                uint32(1), // weight1
                uint32(1e9) // weightCarpet
            )
        );
        bytes memory hookParams = abi.encodePacked(
            FEE_MIN,
            FEE_MAX,
            FEE_QUADRATIC_MULTIPLIER,
            FEE_TWAP_SECONDS_AGO,
            SURGE_FEE,
            SURGE_HALFLIFE,
            SURGE_AUTOSTART_TIME,
            VAULT_SURGE_THRESHOLD_0,
            VAULT_SURGE_THRESHOLD_1,
            REBALANCE_THRESHOLD,
            REBALANCE_MAX_SLIPPAGE,
            REBALANCE_TWAP_SECONDS_AGO,
            REBALANCE_ORDER_TTL,
            true, // amAmmEnabled
            ORACLE_MIN_INTERVAL
        );
        uint160 sqrtPriceX96 = INITIAL_TICK.getSqrtPriceAtTick();
        (, PoolKey memory key) = bunniHub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: uint24(ORACLE_SECS + ORACLE_AGO),
                liquidityDensityFunction: carpetedDoubleGeometricLDF,
                hooklet: address(0),
                statefulLdf: false,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: address(0),
                vault1: address(0),
                minRawTokenRatio0: 0,
                targetRawTokenRatio0: 0,
                maxRawTokenRatio0: 0,
                minRawTokenRatio1: 0,
                targetRawTokenRatio1: 0,
                maxRawTokenRatio1: 0,
                sqrtPriceX96: sqrtPriceX96,
                name: bytes32(0),
                symbol: bytes32(0),
                owner: address(this),
                metadataURI: "",
                salt: bytes32(0)
            })
        );

        // deploy options token and oracle
        oracle = new BunniHookOracle(
            bunniHook,
            key,
            address(paymentToken),
            address(underlyingToken),
            owner,
            ORACLE_MULTIPLIER,
            ORACLE_SECS,
            ORACLE_AGO,
            ORACLE_MIN_PRICE
        );
        optionsToken = new OptionsToken(owner, oracle, treasury);

        // approve tokens
        paymentToken.approve(address(optionsToken), type(uint256).max);
        underlyingToken.approve(address(optionsToken), type(uint256).max);

        // compute initial TWAP value
        int24 arithmeticMeanTick = INITIAL_TICK;
        arithmeticMeanTick = address(paymentToken) == key.currency1 ? arithmeticMeanTick : -arithmeticMeanTick;
        uint256 sqrtPriceWad = sqrtPriceX96.mulDiv(WAD, Q96);
        initialTwap = sqrtPriceWad.mulWad(sqrtPriceWad);
    }

    function test_mint(uint256 amount) public {
        // mint some underlying tokens
        underlyingToken.mint(address(this), amount);

        // mint options tokens using the underlying tokens
        optionsToken.mint(address(this), amount);

        // verify balance
        assertEqDecimal(optionsToken.balanceOf(address(this)), amount, 18);
    }

    function test_exerciseHappyPath(uint256 amount, address recipient) public {
        amount = bound(amount, 0, MAX_SUPPLY);

        // mint options tokens
        underlyingToken.mint(address(this), amount);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount =
            amount.mulWadUp(initialTwap.mulDivUp(ORACLE_MULTIPLIER, ORACLE_MULTIPLIER_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        uint256 actualPaymentAmount = optionsToken.exercise(amount, expectedPaymentAmount, recipient);

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(address(this)), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "total supply not 0");

        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        assertEqDecimal(
            paymentToken.balanceOf(treasury), expectedPaymentAmount, 18, "treasury didn't receive payment tokens"
        );
        assertEqDecimal(actualPaymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
    }

    function test_exerciseMinPrice(uint256 amount, address recipient) public {
        amount = bound(amount, 0, MAX_SUPPLY);

        // mint options tokens
        underlyingToken.mint(address(this), amount);
        optionsToken.mint(address(this), amount);

        // set minPrice such that the strike price is below the oracle's minPrice value
        uint128 newMinPrice = uint128(initialTwap * 2);
        vm.prank(owner);
        oracle.setParams(ORACLE_MULTIPLIER, ORACLE_SECS, ORACLE_AGO, newMinPrice);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(newMinPrice);
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        uint256 actualPaymentAmount = optionsToken.exercise(amount, expectedPaymentAmount, recipient);

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(address(this)), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "total supply not 0");

        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        assertEqDecimal(
            paymentToken.balanceOf(treasury), expectedPaymentAmount, 18, "treasury didn't receive payment tokens"
        );
        assertEqDecimal(actualPaymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
    }

    function test_exerciseHighSlippage(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        underlyingToken.mint(address(this), amount);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount =
            amount.mulWadUp(initialTwap.mulDivUp(ORACLE_MULTIPLIER, ORACLE_MULTIPLIER_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        vm.expectRevert(bytes4(keccak256("OptionsToken__SlippageTooHigh()")));
        optionsToken.exercise(amount, expectedPaymentAmount - 1, recipient);
    }

    function test_exercisePastDeadline(uint256 amount, address recipient, uint256 deadline) public {
        amount = bound(amount, 0, MAX_SUPPLY);
        deadline = bound(deadline, 0, block.timestamp - 1);

        // mint options tokens
        underlyingToken.mint(address(this), amount);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount =
            amount.mulWadUp(initialTwap.mulDivUp(ORACLE_MULTIPLIER, ORACLE_MULTIPLIER_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        vm.expectRevert(bytes4(keccak256("OptionsToken__PastDeadline()")));
        optionsToken.exercise(amount, expectedPaymentAmount, recipient, deadline);
    }
}
