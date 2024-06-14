pragma solidity ^0.8.25;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IL1OpUSDCBridgeAdapter, L1OpUSDCBridgeAdapter} from 'contracts/L1OpUSDCBridgeAdapter.sol';
import {IOpUSDCBridgeAdapter} from 'interfaces/IOpUSDCBridgeAdapter.sol';
import {Helpers} from 'test/utils/Helpers.sol';

contract ForTestL1OpUSDCBridgeAdapter is L1OpUSDCBridgeAdapter {
  constructor(
    address _usdc,
    address _messenger,
    address _linkedAdapter,
    address _owner
  ) L1OpUSDCBridgeAdapter(_usdc, _messenger, _linkedAdapter, _owner) {}

  function forTest_setBurnAmount(uint256 _amount) external {
    burnAmount = _amount;
  }

  function forTest_setCircle(address _circle) external {
    circle = _circle;
  }

  function forTest_setMessengerStatus(Status _status) external {
    messengerStatus = _status;
  }
}

abstract contract Base is Helpers {
  ForTestL1OpUSDCBridgeAdapter public adapter;

  bytes32 internal _salt = bytes32('1');
  address internal _user = makeAddr('user');
  address internal _owner = makeAddr('owner');
  address internal _signerAd;
  uint256 internal _signerPk;
  address internal _usdc = makeAddr('opUSDC');
  address internal _linkedAdapter = makeAddr('linkedAdapter');

  // cant fuzz this because of foundry's VM
  address internal _messenger = makeAddr('messenger');

  event MigratingToNative(address _messenger, address _newOwner);
  event BurnAmountSet(uint256 _burnAmount);
  event MigrationComplete();
  event MessageSent(address _user, address _to, uint256 _amount, address _messenger, uint32 _minGasLimit);
  event MessageReceived(address _user, uint256 _amount, address _messenger);

  function setUp() public virtual {
    (_signerAd, _signerPk) = makeAddrAndKey('signer');
    vm.etch(_messenger, 'xDomainMessageSender');

    adapter = new ForTestL1OpUSDCBridgeAdapter(_usdc, _messenger, _linkedAdapter, _owner);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_Constructor is Base {
  /**
   * @notice Check that the constructor works as expected
   */
  function test_constructorParams() public {
    assertEq(adapter.USDC(), _usdc, 'USDC should be set to the provided address');
    assertEq(adapter.LINKED_ADAPTER(), _linkedAdapter, 'Linked adapter should be set to the provided address');
    assertEq(adapter.MESSENGER(), _messenger, 'Messenger should be set to the provided address');
    assertEq(adapter.owner(), _owner, 'Owner should be set to the provided address');
  }
}

/*///////////////////////////////////////////////////////////////
                          MIGRATION
///////////////////////////////////////////////////////////////*/
contract L1OpUSDCBridgeAdapter_Unit_MigrateToNative is Base {
  /**
   * @notice Check that the function reverts if the sender is not the upgrade manager
   */
  function test_onlyOwner(
    address _executor,
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_executor != _owner);
    // Execute
    vm.prank(_executor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }

  /**
   * @notice Check that the function reverts if `_circle` is the zero address
   */
  function test_revertOnAddressZero(uint32 _minGasLimitReceiveOnL2, uint32 _minGasLimitSetBurnAmount) external {
    // Execute
    vm.prank(_owner);
    vm.expectRevert(abi.encodeWithSelector(IL1OpUSDCBridgeAdapter.IL1OpUSDCBridgeAdapter_InvalidAddress.selector));
    adapter.migrateToNative(address(0), _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }

  /**
   * @notice Check that the function reverts if a messenger is not active or upgrading
   */
  function test_revertIfMessengerNotActive(
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_newOwner != address(0));
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);

    // Execute
    vm.prank(_owner);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessagingDisabled.selector);
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }

  /**
   * @notice Check that the function updates the state as expected
   */
  function test_StateOfMigration(
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_newOwner != address(0));
    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMigrateToNative(address,uint32)', _newOwner, _minGasLimitSetBurnAmount),
        _minGasLimitReceiveOnL2
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_owner);
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
    assertEq(adapter.circle(), _newOwner, 'Circle should be set to the new owner');
    assertEq(
      uint256(adapter.messengerStatus()),
      uint256(IL1OpUSDCBridgeAdapter.Status.Upgrading),
      'Is upgrading should be set to true'
    );
  }

  /**
   * @notice Check that the function calls the expected functions
   */
  function test_expectCall(
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_newOwner != address(0));
    _mockAndExpect(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMigrateToNative(address,uint32)', _newOwner, _minGasLimitSetBurnAmount),
        _minGasLimitReceiveOnL2
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_owner);
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }

  /**
   * @notice Check that we can recall the function if its upgrading
   */
  function test_recallWhenUpgrading(
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_newOwner != address(0));
    adapter.forTest_setCircle(_newOwner);
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Upgrading);

    _mockAndExpect(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMigrateToNative(address,uint32)', _newOwner, _minGasLimitSetBurnAmount),
        _minGasLimitReceiveOnL2
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_owner);
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEventMigrating(
    address _newOwner,
    uint32 _minGasLimitReceiveOnL2,
    uint32 _minGasLimitSetBurnAmount
  ) external {
    vm.assume(_newOwner != address(0));
    // Mock calls
    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMigrateToNative(address,uint32)', _newOwner, _minGasLimitSetBurnAmount),
        _minGasLimitReceiveOnL2
      ),
      abi.encode()
    );

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MigratingToNative(_messenger, _newOwner);

    // Execute
    vm.prank(_owner);
    adapter.migrateToNative(_newOwner, _minGasLimitReceiveOnL2, _minGasLimitSetBurnAmount);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_SetBurnAmount is Base {
  /**
   * @notice Check that the function reverts if the sender is not the messenger
   */
  function test_revertIfMessengerDidntSendTheMessage(uint256 _amount, address _notMessager) external {
    vm.assume(_notMessager != _messenger);
    // Execute
    vm.prank(_notMessager);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSender.selector);
    adapter.setBurnAmount(_amount);
  }

  /**
   * @notice Check that the function reverts if the linked adapter didn't send the message
   */
  function test_revertIfLinkedAdapterDidntSendTheMessage(uint256 _amount, address _messageSender) external {
    vm.assume(_messageSender != _linkedAdapter);
    // Mock calls
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_messageSender));

    // Execute
    vm.prank(_messenger);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSender.selector);
    adapter.setBurnAmount(_amount);
  }

  /**
   * @notice Check the functions reverts when messenger status is not upgrading
   */
  function test_revertIfMessengerStatusIsNotUpgrading(uint256 _amount, uint256 _status) external {
    _status = bound(_status, 0, uint256(type(IL1OpUSDCBridgeAdapter.Status).max) - 1);
    vm.assume(_status != uint256(IL1OpUSDCBridgeAdapter.Status.Upgrading));

    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status(_status));

    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    // Execute
    vm.prank(_messenger);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_NotUpgrading.selector);
    adapter.setBurnAmount(_amount);
  }

  /**
   * @notice Check that the burn amount is set as expected
   */
  function test_setAmount(uint256 _burnAmount) external {
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Upgrading);

    // Execute
    vm.prank(_messenger);
    adapter.setBurnAmount(_burnAmount);

    // Assert
    assertEq(adapter.burnAmount(), _burnAmount, 'Burn amount should be set');
  }

  /**
   * @notice Check that the status is set as expected
   */
  function test_setStatus(uint256 _burnAmount) external {
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Upgrading);

    // Execute
    vm.prank(_messenger);
    adapter.setBurnAmount(_burnAmount);

    // Assert
    assertEq(
      uint256(adapter.messengerStatus()),
      uint256(IL1OpUSDCBridgeAdapter.Status.Deprecated),
      'Messenger status should be set to Deprecated'
    );
  }
  /**
   * @notice Check that the event is emitted as expected
   */

  function test_emitEvent(uint256 _burnAmount) external {
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Upgrading);

    // Execute
    vm.prank(_messenger);
    vm.expectEmit(true, true, true, true);
    emit BurnAmountSet(_burnAmount);
    adapter.setBurnAmount(_burnAmount);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_BurnLockedUSDC is Base {
  /**
   * @notice Check that only the owner can burn the locked USDC
   */
  function test_onlyCircle() external {
    // Execute
    vm.prank(_user);
    vm.expectRevert(abi.encodeWithSelector(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSender.selector));
    adapter.burnLockedUSDC();
  }

  function test_burnAmountNotSet(address _circle) external {
    adapter.forTest_setCircle(_circle);

    // Execute
    vm.prank(_circle);
    vm.expectRevert(IL1OpUSDCBridgeAdapter.IL1OpUSDCBridgeAdapter_BurnAmountNotSet.selector);
    adapter.burnLockedUSDC();
  }

  /**
   * @notice Check that the burn function is called as expected
   */
  function test_expectedCall(uint256 _burnAmount, address _circle) external {
    adapter.forTest_setCircle(_circle);
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Deprecated);

    vm.assume(_burnAmount > 0);

    _mockAndExpect(
      address(_usdc), abi.encodeWithSignature('burn(address,uint256)', address(adapter), _burnAmount), abi.encode(true)
    );

    adapter.forTest_setBurnAmount(_burnAmount);

    // Execute
    vm.prank(_circle);
    adapter.burnLockedUSDC();
  }

  /**
   * @notice Check that the burn amount is set to 0 after burning
   */
  function test_resetStorageValues(uint256 _burnAmount, address _circle) external {
    vm.assume(_burnAmount > 0);
    adapter.forTest_setCircle(_circle);
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Deprecated);

    vm.mockCall(
      address(_usdc), abi.encodeWithSignature('burn(address,uint256)', address(adapter), _burnAmount), abi.encode(true)
    );

    adapter.forTest_setBurnAmount(_burnAmount);

    // Execute
    vm.prank(_circle);
    adapter.burnLockedUSDC();

    assertEq(adapter.burnAmount(), 0, 'Burn amount should be set to 0');
    assertEq(adapter.circle(), address(0), 'Circle should be set to 0');
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(uint256 _burnAmount, address _circle) external {
    vm.assume(_burnAmount > 0);
    adapter.forTest_setCircle(_circle);
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Deprecated);

    vm.mockCall(
      address(_usdc), abi.encodeWithSignature('burn(address,uint256)', address(adapter), _burnAmount), abi.encode(true)
    );

    adapter.forTest_setBurnAmount(_burnAmount);

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MigrationComplete();

    // Execute
    vm.prank(_circle);
    adapter.burnLockedUSDC();
  }
}

/*///////////////////////////////////////////////////////////////
                      MESSAGING CONTROL
///////////////////////////////////////////////////////////////*/
contract L1OpUSDCBridgeAdapter_Unit_StopMessaging is Base {
  event MessagingStopped(address _messenger);

  /**
   * @notice Check that only the owner can stop messaging
   */
  function test_onlyOwner(address _executor) public {
    vm.assume(_executor != _owner);
    // Execute
    vm.prank(_executor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
    adapter.stopMessaging(0);
  }

  /**
   * @notice Check that the function reverts if messaging is already disabled
   */
  function test_revertIfMessagingIsAlreadyPaused(uint32 _minGasLimit) public {
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);
    // Execute
    vm.prank(_owner);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessagingDisabled.selector);
    adapter.stopMessaging(_minGasLimit);
  }

  /**
   * @notice Check that messenger status gets set to paused
   */
  function test_setMessengerStatusToPaused(uint32 _minGasLimit) public {
    bytes memory _messageData = abi.encodeWithSignature('receiveStopMessaging()');

    _mockAndExpect(
      _messenger,
      abi.encodeWithSignature('sendMessage(address,bytes,uint32)', _linkedAdapter, _messageData, _minGasLimit),
      abi.encode('')
    );

    // Execute
    vm.prank(_owner);
    adapter.stopMessaging(_minGasLimit);
    assertEq(
      uint256(adapter.messengerStatus()), uint256(IL1OpUSDCBridgeAdapter.Status.Paused), 'Messenger should be paused'
    );
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(uint32 _minGasLimit) public {
    bytes memory _messageData = abi.encodeWithSignature('receiveStopMessaging()');

    /// Mock calls
    vm.mockCall(
      _messenger,
      abi.encodeWithSignature('sendMessage(address,bytes,uint32)', _linkedAdapter, _messageData, _minGasLimit),
      abi.encode('')
    );

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MessagingStopped(_messenger);

    // Execute
    vm.prank(_owner);
    adapter.stopMessaging(_minGasLimit);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_ResumeMessaging is Base {
  event MessagingResumed(address _messenger);

  /**
   * @notice Check that only the owner can resume messaging
   */
  function test_onlyOwner(address _executor, uint32 _minGasLimit) external {
    vm.assume(_executor != _owner);
    // Execute
    vm.prank(_executor);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
    adapter.resumeMessaging(_minGasLimit);
  }

  /**
   * @notice Check that it reverts if bridging is not paused
   */
  function test_RevertIfBridgingIsNotPaused(uint32 _minGasLimit) external {
    // Execute
    vm.prank(_owner);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessagingEnabled.selector);
    adapter.resumeMessaging(_minGasLimit);
  }

  /**
   * @notice Check that the messenger status is set to active
   */
  function test_setMessengerStatusToActive(uint32 _minGasLimit) external {
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);
    _mockAndExpect(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveResumeMessaging()'),
        _minGasLimit
      ),
      abi.encode('')
    );

    // Execute
    vm.prank(_owner);
    adapter.resumeMessaging(_minGasLimit);
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(uint32 _minGasLimit) external {
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);
    // Mock calls
    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveResumeMessaging()'),
        _minGasLimit
      ),
      abi.encode('')
    );

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MessagingResumed(_messenger);

    // Execute
    vm.prank(_owner);
    adapter.resumeMessaging(_minGasLimit);
  }
}

/*///////////////////////////////////////////////////////////////
                          MESSAGING
///////////////////////////////////////////////////////////////*/
contract L1OpUSDCBridgeAdapter_Unit_SendMessage is Base {
  /**
   * @notice Check that the function reverts if messager is not active
   */
  function test_revertOnMessengerNotActive(address _to, uint256 _amount, uint32 _minGasLimit) external {
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);
    // Execute
    vm.prank(_user);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessagingDisabled.selector);
    adapter.sendMessage(_to, _amount, _minGasLimit);
  }

  /**
   * @notice Check that transferFrom and sendMessage are called as expected
   */
  function test_expectedCall(address _to, uint256 _amount, uint32 _minGasLimit) external {
    _mockAndExpect(
      address(_usdc),
      abi.encodeWithSignature('transferFrom(address,address,uint256)', _user, address(adapter), _amount),
      abi.encode(true)
    );
    _mockAndExpect(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMessage(address,uint256)', _to, _amount),
        _minGasLimit
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_user);
    adapter.sendMessage(_to, _amount, _minGasLimit);
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(address _to, uint256 _amount, uint32 _minGasLimit) external {
    // Mock calls
    vm.mockCall(
      address(_usdc),
      abi.encodeWithSignature('transferFrom(address,address,uint256)', _user, address(adapter), _amount),
      abi.encode(true)
    );

    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMessage(address,uint256)', _to, _amount),
        _minGasLimit
      ),
      abi.encode()
    );

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MessageSent(_user, _to, _amount, _messenger, _minGasLimit);

    // Execute
    vm.prank(_user);
    adapter.sendMessage(_to, _amount, _minGasLimit);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_SendMessageWithSignature is Base {
  /**
   * @notice Check that the function reverts if messaging is disabled
   */
  function test_revertOnMessengerNotActive(
    address _to,
    uint256 _amount,
    bytes memory _signature,
    uint256 _deadline,
    uint32 _minGasLimit
  ) external {
    adapter.forTest_setMessengerStatus(IL1OpUSDCBridgeAdapter.Status.Paused);
    // Execute
    vm.prank(_user);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessagingDisabled.selector);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
  }

  /**
   * @notice Check that the function reverts if the deadline is in the past
   */
  function test_revertOnExpiredMessage(
    address _to,
    uint256 _amount,
    bytes memory _signature,
    uint256 _timestamp,
    uint256 _deadline,
    uint32 _minGasLimit
  ) external {
    vm.assume(_timestamp > _deadline);
    vm.warp(_timestamp);

    // Execute
    vm.prank(_user);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_MessageExpired.selector);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
  }

  /**
   * @notice Check that the function reverts on invalid signature
   */
  function test_invalidSignature(address _to, uint256 _amount, uint256 _deadline, uint32 _minGasLimit) external {
    vm.assume(_deadline > 0);
    vm.warp(_deadline - 1);
    uint256 _nonce = adapter.userNonce(_signerAd);
    (address _notSignerAd, uint256 _notSignerPk) = makeAddrAndKey('notSigner');
    bytes memory _signature = _generateSignature(_to, _amount, _nonce, _notSignerAd, _notSignerPk, address(adapter));

    // Execute
    vm.prank(_user);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSignature.selector);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
  }

  /**
   * @notice Check nonce increment
   */
  function test_nonceIncrement(address _to, uint256 _amount, uint256 _deadline, uint32 _minGasLimit) external {
    vm.assume(_deadline > 0);
    vm.warp(_deadline - 1);
    uint256 _nonce = adapter.userNonce(_signerAd);
    bytes memory _signature = _generateSignature(_to, _amount, _nonce, _signerAd, _signerPk, address(adapter));

    vm.mockCall(
      address(_usdc),
      abi.encodeWithSignature('transferFrom(address,address,uint256)', _signerAd, address(adapter), _amount),
      abi.encode(true)
    );
    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMessage(address,uint256)', _to, _amount),
        _minGasLimit
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_user);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
    assertEq(adapter.userNonce(_signerAd), _nonce + 1, 'Nonce should be incremented');
  }

  /**
   * @notice Check that transferFrom and sendMessage are called as expected
   */
  function test_expectedCall(address _to, uint256 _amount, uint256 _deadline, uint32 _minGasLimit) external {
    vm.assume(_deadline > 0);
    vm.warp(_deadline - 1);
    uint256 _nonce = adapter.userNonce(_signerAd);
    bytes memory _signature = _generateSignature(_to, _amount, _nonce, _signerAd, _signerPk, address(adapter));

    _mockAndExpect(
      address(_usdc),
      abi.encodeWithSignature('transferFrom(address,address,uint256)', _signerAd, address(adapter), _amount),
      abi.encode(true)
    );
    _mockAndExpect(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMessage(address,uint256)', _to, _amount),
        _minGasLimit
      ),
      abi.encode()
    );

    // Execute
    vm.prank(_user);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(address _to, uint256 _amount, uint256 _deadline, uint32 _minGasLimit) external {
    vm.assume(_deadline > 0);
    vm.warp(_deadline - 1);
    uint256 _nonce = adapter.userNonce(_signerAd);
    bytes memory _signature = _generateSignature(_to, _amount, _nonce, _signerAd, _signerPk, address(adapter));

    vm.mockCall(
      address(_usdc),
      abi.encodeWithSignature('transferFrom(address,address,uint256)', _signerAd, address(adapter), _amount),
      abi.encode(true)
    );
    vm.mockCall(
      address(_messenger),
      abi.encodeWithSignature(
        'sendMessage(address,bytes,uint32)',
        _linkedAdapter,
        abi.encodeWithSignature('receiveMessage(address,uint256)', _to, _amount),
        _minGasLimit
      ),
      abi.encode()
    );

    // Expect events
    vm.expectEmit(true, true, true, true);
    emit MessageSent(_signerAd, _to, _amount, _messenger, _minGasLimit);
    // Execute
    vm.prank(_user);
    adapter.sendMessage(_signerAd, _to, _amount, _signature, _deadline, _minGasLimit);
  }
}

contract L1OpUSDCBridgeAdapter_Unit_ReceiveMessage is Base {
  /**
   * @notice Check that the function reverts if the sender is not the messenger
   */
  function test_revertIfNotMessenger(uint256 _amount) external {
    // Execute
    vm.prank(_user);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSender.selector);
    adapter.receiveMessage(_user, _amount);
  }

  /**
   * @notice Check that the function reverts if the linked adapter didn't send the message
   */
  function test_revertIfLinkedAdapterDidntSendTheMessage(uint256 _amount, address _messageSender) external {
    vm.assume(_messageSender != _linkedAdapter);
    // Mock calls
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_messageSender));

    // Execute
    vm.prank(_messenger);
    vm.expectRevert(IOpUSDCBridgeAdapter.IOpUSDCBridgeAdapter_InvalidSender.selector);
    adapter.receiveMessage(_user, _amount);
  }

  /**
   * @notice Check that token transfer is called as expected
   */
  function test_sendTokens(uint256 _amount) external {
    // Mock calls
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    _mockAndExpect(
      address(_usdc), abi.encodeWithSignature('transfer(address,uint256)', _user, _amount), abi.encode(true)
    );

    // Execute
    vm.prank(_messenger);
    adapter.receiveMessage(_user, _amount);
  }

  /**
   * @notice Check that the event is emitted as expected
   */
  function test_emitEvent(uint256 _amount) external {
    // Mock calls
    vm.mockCall(address(_messenger), abi.encodeWithSignature('xDomainMessageSender()'), abi.encode(_linkedAdapter));

    vm.mockCall(address(_usdc), abi.encodeWithSignature('transfer(address,uint256)', _user, _amount), abi.encode(true));

    // Execute
    vm.expectEmit(true, true, true, true);
    emit MessageReceived(_user, _amount, _messenger);

    vm.prank(_messenger);
    adapter.receiveMessage(_user, _amount);
  }
}
