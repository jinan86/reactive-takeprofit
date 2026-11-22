// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceOracle } from "../src/MockPriceOracle.sol";
import { OrderVault } from "../src/OrderVault.sol";
import { TakeProfitReactive } from "../src/TakeProfitReactive.sol";
import { OrderExecutor } from "../src/OrderExecutor.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Mock of the Reactive system contract, etched at the real SYSTEM
/// address so subscribe()/react() execute (same pattern as Sentinel tests).
contract MockSystemTP {
    struct CallbackReq {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256 public subscribeCalls;
    uint256 public callbackCount;
    CallbackReq[] public callbackRequests;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        callbackCount++;
        callbackRequests.push(CallbackReq(c.chainId, c.recipient, c.gasLimit, c.payload));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function depositTo(address) external payable {}

    receive() external payable {}
}

/// @notice Unit tests for the TakeProfit core. No fork needed.
contract TakeProfitUnitTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant PROXY = address(0xBEEF);
    address internal constant FAKE_REACTIVE = address(0xCA11);
    address internal constant USER = address(0xA11CE);
    address internal constant PAYEE = address(0x9A7EE);

    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdate(uint256,uint256)"));
    uint256 internal constant CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,address,uint256,uint256,address)"));
    uint256 internal constant CANCELLED_TOPIC0 = uint256(keccak256("OrderCancelled(uint256)"));

    uint256 internal constant TARGET = 2000_00000000; // $2000, 8 decimals
    uint256 internal constant BELOW = 1500_00000000; // $1500
    uint256 internal constant ABOVE = 2100_00000000; // $2100

    MockToken internal tUSD;
    MockToken internal tTOKEN;
    MockPriceOracle internal oracle;
    OrderVault internal vault;
    TakeProfitReactive internal reactive;
    OrderExecutor internal executor;
    MockSystemTP internal mockSystem;

    function setUp() public {
        mockSystem = new MockSystemTP();
        vm.etch(SYSTEM, address(mockSystem).code);
        tUSD = new MockToken("TakeProfit Demo USD", "tUSD");
        tTOKEN = new MockToken("TakeProfit Demo Token", "tTOKEN");
        oracle = new MockPriceOracle(BELOW);
        vault = new OrderVault(address(tUSD));
        reactive = new TakeProfitReactive(address(oracle), address(vault), PRICE_TOPIC0, CREATED_TOPIC0, CANCELLED_TOPIC0);
        executor = new OrderExecutor(IPayable(payable(PROXY)), address(reactive), address(vault), address(oracle));
        vault.setExecutor(address(executor));
        reactive.setExecutor(address(executor));
        // Proceeds pool: 1,000,000 tUSD in the vault.
        tUSD.mint(address(vault), 1_000_000 ether);
        // User holds 100 tTOKEN.
        tTOKEN.mint(USER, 100 ether);
        vm.prank(USER);
        tTOKEN.approve(address(vault), type(uint256).max);
    }

    // ---- helpers ----

    /// @notice The mock system's state lives at the SYSTEM address (code
    /// etched there); read it through that address, not the instance.
    function _sys() internal view returns (MockSystemTP) {
        return MockSystemTP(payable(SYSTEM));
    }

    function _createOrder() internal returns (uint256 id) {
        vm.prank(USER);
        id = vault.createOrder(address(tTOKEN), 10 ether, TARGET, PAYEE);
    }

    function _mirrorOrder(uint256 id) internal {
        // Feed the real OrderCreated log shape into react() as SYSTEM.
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(vault),
            topic0: CREATED_TOPIC0,
            topic1: id,
            topic2: uint256(uint160(USER)),
            topic3: uint256(uint160(address(tTOKEN))),
            data: abi.encode(uint256(10 ether), TARGET, PAYEE),
            blockNumber: block.number,
            opCode: 4, // OrderCreated is LOG4
            blockHash: uint256(blockhash(block.number - 1)),
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM);
        reactive.react(log);
    }

    function _priceLog(uint256 price) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, block.timestamp),
            blockNumber: block.number,
            opCode: 1, // PriceUpdate is LOG1
            blockHash: uint256(blockhash(block.number - 1)),
            txHash: 0,
            logIndex: 0
        });
    }

    function _reactPrice(uint256 price) internal {
        vm.prank(SYSTEM);
        reactive.react(_priceLog(price));
    }

    // ---- MockPriceOracle ----

    function testSetPriceOnlyOwner() public {
        vm.prank(USER);
        vm.expectRevert();
        oracle.setPrice(ABOVE);
        oracle.setPrice(ABOVE);
        assertEq(oracle.price(), ABOVE);
    }

    // ---- OrderVault: create / cancel ----

    function testCreateOrderLocksTokens() public {
        uint256 id = _createOrder();
        assertEq(id, 1);
        assertEq(tTOKEN.balanceOf(address(vault)), 10 ether);
        assertEq(tTOKEN.balanceOf(USER), 90 ether);
        OrderVault.Order memory o = vault.getOrder(id);
        assertEq(o.owner, USER);
        assertEq(o.amount, 10 ether);
        assertEq(o.targetPrice, TARGET);
        assertEq(o.payee, PAYEE);
        assertTrue(o.active);
        assertFalse(o.executed);
    }

    function testCreateOrderRejectsZeroAmountTargetAndPayee() public {
        vm.prank(USER);
        vm.expectRevert();
        vault.createOrder(address(tTOKEN), 0, TARGET, PAYEE);
        vm.prank(USER);
        vm.expectRevert();
        vault.createOrder(address(tTOKEN), 10 ether, 0, PAYEE);
        vm.prank(USER);
        vm.expectRevert();
        vault.createOrder(address(tTOKEN), 10 ether, TARGET, address(0));
    }

    function testCancelRefundsAndBlocksExecution() public {
        uint256 id = _createOrder();
        vm.prank(USER);
        vault.cancelOrder(id);
        assertEq(tTOKEN.balanceOf(USER), 100 ether);
        assertEq(tTOKEN.balanceOf(address(vault)), 0);
        assertFalse(vault.getOrder(id).active);
        // Executor can no longer execute the cancelled order.
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(address(reactive), id);
    }

    function testCancelOnlyOrderOwner() public {
        uint256 id = _createOrder();
        vm.prank(PAYEE);
        vm.expectRevert();
        vault.cancelOrder(id);
    }

    function testExecuteOrderDirectlyWithoutExecutorReverts() public {
        uint256 id = _createOrder();
        vm.expectRevert();
        vault.executeOrder(id, ABOVE);
    }

    // ---- TakeProfitReactive: below target = no action ----

    function testReactBelowTargetNoCallback() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        assertEq(reactive.reactCount(), 1); // the OrderCreated react
        _reactPrice(BELOW);
        assertEq(reactive.reactCount(), 2);
        assertEq(reactive.actedCount(), 0);
        assertEq(reactive.lastPrice(), BELOW);
        assertEq(_sys().callbackCount(), 0);
        assertTrue(vault.getOrder(id).active);
        assertFalse(vault.getOrder(id).executed);
    }

    function testReactFiresOnRealisticOpcodes() public {
        // Regression test for the v1 bug: an `opCode != 3` gate silently
        // dropped every event (PriceUpdate LOG1, OrderCancelled LOG2,
        // OrderCreated LOG4). Dispatch is on topic0, so all three fire.
        uint256 id = _createOrder();
        _mirrorOrder(id); // opCode 4
        assertEq(reactive.reactCount(), 1);
        _reactPrice(ABOVE); // opCode 1
        assertEq(reactive.reactCount(), 2);
        assertEq(reactive.actedCount(), 1);
    }

    function testReactIgnoresNonMatchingTopic() public {
        IReactive.LogRecord memory log = _priceLog(ABOVE);
        log.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        vm.prank(SYSTEM);
        reactive.react(log);
        assertEq(reactive.reactCount(), 0);
    }

    function testReactRejectsNonSystemCaller() public {
        vm.expectRevert();
        reactive.react(_priceLog(ABOVE));
    }

    function testReactCancelUnmirrorsOrder() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        vm.prank(USER);
        vault.cancelOrder(id);
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(vault),
            topic0: CANCELLED_TOPIC0,
            topic1: id,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 2, // OrderCancelled is LOG2
            blockHash: uint256(blockhash(block.number - 1)),
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM);
        reactive.react(log);
        (uint256 tp, , , bool active) = reactive.mirrored(id);
        assertEq(tp, TARGET);
        assertFalse(active);
        // Price above target now triggers nothing for the cancelled order.
        _reactPrice(ABOVE);
        assertEq(reactive.actedCount(), 0);
        assertEq(_sys().callbackCount(), 0);
    }

    // ---- Full flow: target hit -> exactly one execution, exact proceeds ----

    function testTargetHitRequestsCallbackAndExecutesExactlyOnce() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        _reactPrice(ABOVE);
        assertEq(reactive.actedCount(), 1);
        assertEq(_sys().callbackCount(), 1);
        (uint256 cbChain, address cbRecipient, uint64 cbGas, bytes memory cbPayload) = _sys().callbackRequests(0);
        assertEq(cbChain, 84532);
        assertEq(cbRecipient, address(executor));
        assertGe(cbGas, 100_000);
        assertEq(cbPayload, abi.encodeWithSignature("execute(address,uint256)", address(0), id));

        // Oracle must show the trigger price before the callback settles.
        oracle.setPrice(ABOVE);
        uint256 payeeBefore = tUSD.balanceOf(PAYEE);
        vm.prank(PROXY);
        uint256 proceeds = executor.execute(address(reactive), id);
        // proceeds = 10 tTOKEN * $2100 = 21,000 tUSD (exact).
        assertEq(proceeds, 21_000 ether);
        assertEq(tUSD.balanceOf(PAYEE) - payeeBefore, 21_000 ether);
        assertTrue(vault.getOrder(id).executed);
        assertFalse(vault.getOrder(id).active);

        // Second execution must fail — an order can never execute twice.
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(address(reactive), id);
        assertEq(tUSD.balanceOf(PAYEE) - payeeBefore, 21_000 ether);
    }

    function testExactTargetPriceTriggers() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        _reactPrice(TARGET); // price == target counts as reached
        assertEq(reactive.actedCount(), 1);
        oracle.setPrice(TARGET);
        vm.prank(PROXY);
        uint256 proceeds = executor.execute(address(reactive), id);
        assertEq(proceeds, 20_000 ether); // 10 * $2000 exact
        assertEq(tUSD.balanceOf(PAYEE), 20_000 ether);
    }

    // ---- Executor: re-checks + auth ----

    function testExecutorRejectsNonProxyCaller() public {
        uint256 id = _createOrder();
        vm.prank(USER);
        vm.expectRevert();
        executor.execute(address(reactive), id);
    }

    function testExecutorRejectsWrongReactiveSender() public {
        uint256 id = _createOrder();
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(FAKE_REACTIVE, id);
    }

    function testExecutorReChecksPriceBeforeSettling() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        // Reactive saw a high price and requested a callback, but by the
        // time the callback lands the oracle price has dropped below target.
        _reactPrice(ABOVE);
        assertEq(reactive.actedCount(), 1);
        // oracle.price() is still BELOW (setUp value) — callback must fail.
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(address(reactive), id);
        assertFalse(vault.getOrder(id).executed);
        assertTrue(vault.getOrder(id).active);
    }

    function testExecutorRefusesAlreadyExecutedOrder() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        oracle.setPrice(ABOVE);
        vm.prank(PROXY);
        executor.execute(address(reactive), id);
        // A duplicate callback (e.g. a second PriceUpdate above target)
        // must fail instead of paying twice.
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(address(reactive), id);
    }

    function testDuplicatePriceUpdateRequestsDuplicateCallbackButPaysOnce() public {
        uint256 id = _createOrder();
        _mirrorOrder(id);
        _reactPrice(ABOVE);
        _reactPrice(ABOVE + 100_00000000);
        assertEq(reactive.actedCount(), 2);
        assertEq(_sys().callbackCount(), 2);
        oracle.setPrice(ABOVE);
        vm.prank(PROXY);
        executor.execute(address(reactive), id);
        vm.prank(PROXY);
        vm.expectRevert();
        executor.execute(address(reactive), id);
        assertEq(tUSD.balanceOf(PAYEE), 21_000 ether);
    }
}
