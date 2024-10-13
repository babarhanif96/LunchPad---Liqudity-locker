// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.0;
//please add update version of solidity

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

library TransferHelper {
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x095ea7b3, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: APPROVE_FAILED"
        );
    }

    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: TRANSFER_FAILED"
        );
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: TRANSFER_FROM_FAILED"
        );
    }
}

interface IUniswapV2Pair {
    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IUniFactory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address);
}

contract DLock is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    IUniFactory public uniswapFactory;

    struct UserInfo {
        EnumerableSet.AddressSet lockedTokens; //  records of user's locked tokens
        mapping(address => uint256[]) locksForToken; // toekn address -> lock id
    }

    struct TokenLock {
        uint256 lockDate; // locked date
        uint256 amount; // locked tokens amount
        uint256 initialAmount; // the initial lock amount
        uint256 unlockDate; // unlock date
        uint256 lockID; // lock id per token
        address owner; // lock owner
    }

    mapping(address => UserInfo) private users; // user address -> user info

    EnumerableSet.AddressSet private lockedTokens;
    mapping(address => TokenLock[]) public tokenLocks;

    struct FeeStruct {
        uint256 ethFee; // fee to lock
    }

    FeeStruct public gFees;

    address payable devaddr;
    address payable multiSigAddr;

    event onDeposit(
        address indexed Token,
        address indexed user,
        uint256 amount,
        uint256 lockDate,
        uint256 unlockDate
    );
    event onWithdraw(address indexed Token, uint256 amount);
    event onTranferLockOwnership(
        address indexed Token,
        address indexed oldOwner,
        address newOwner
    );
    event onRelock(address indexed Token, uint256 amount);

    constructor(IUniFactory _uniswapFactory, address payable _devAddress, address payable _multiSigAddr) {
        devaddr = _devAddress;
        multiSigAddr = _multiSigAddr;
        gFees.ethFee = 75000000000000000; // initial fee set to 0.075 ETH
        uniswapFactory = _uniswapFactory;
    }

    function setDev(address payable _devAddress) external {
        require(_msgSender() == multiSigAddr);
        devaddr = _devAddress;
    }

    function setMultiSig(address payable _multiSigAddr) external {
        require(_msgSender() == multiSigAddr);
        multiSigAddr = _multiSigAddr;
    }

    function setFees(uint256 _ethFee) external onlyOwner {
        require(_msgSender() == multiSigAddr);
        gFees.ethFee = _ethFee;
    }

    /**
     * @notice new lock
     * @param _lockToken address of token to lock
     * @param _amount amount of tokens to lock
     * @param _unlock_date timestamp until unlock
     * @param _is_lp_tokens is the token an LP token use 1 to confirm, any other value will default to token lock
     * @param _lock_owner owner of the lock
     */
    function lockTokens(
        address _lockToken,
        uint256 _amount,
        uint256 _unlock_date,
        uint256 _is_lp_tokens,
        address payable _lock_owner
    ) external payable nonReentrant {
        require(_unlock_date < 10000000000, "DLock: TIMESTAMP INVALID"); // no milliseconds
        require(_amount > 0, "DLock: INSUFFICIENT"); // no 0 tokens

        // check if the lock is for an LP token
        if (_is_lp_tokens == 1) {
            // check if the pair is valid
            IUniswapV2Pair lpair = IUniswapV2Pair(address(_lockToken));
            address factoryPairAddress = uniswapFactory.getPair(
                lpair.token0(),
                lpair.token1()
            );
            require(
                factoryPairAddress == address(_lockToken),
                "DLock: NOT UNIV2"
            );
            TransferHelper.safeTransferFrom(
                _lockToken,
                address(msg.sender),
                address(this),
                _amount
            );
        } else {
            TransferHelper.safeTransferFrom(
                _lockToken,
                address(msg.sender),
                address(this),
                _amount
            );
        }

        // check if fee is met
        uint256 ethFee = gFees.ethFee;
        require(msg.value == ethFee, "DLock: FEE NOT MET");
        if (ethFee > 0) {
            devaddr.transfer(ethFee);
        }

        TokenLock memory the_lock;
        the_lock.lockDate = block.timestamp;
        the_lock.amount = _amount;
        the_lock.initialAmount = _amount;
        the_lock.unlockDate = _unlock_date;
        the_lock.lockID = tokenLocks[_lockToken].length;
        the_lock.owner = _lock_owner;

        // store record of token lock
        tokenLocks[_lockToken].push(the_lock);
        lockedTokens.add(_lockToken);

        // store record of user's lock
        UserInfo storage user = users[_lock_owner];
        user.lockedTokens.add(_lockToken);
        uint256[] storage user_locks = user.locksForToken[_lockToken];
        user_locks.push(the_lock.lockID);

        emit onDeposit(
            _lockToken,
            msg.sender,
            the_lock.amount,
            the_lock.lockDate,
            the_lock.unlockDate
        );
    }

    /**
     * @notice extend a token's lock
     */
    function relock(
        address _lockToken,
        uint256 _index,
        uint256 _lock_id,
        uint256 _unlock_date
    ) external payable nonReentrant {
        require(_unlock_date < 10000000000, "DLock: TIMESTAMP INVALID");
        uint256 lock_id = users[msg.sender].locksForToken[_lockToken][_index];
        TokenLock storage userLock = tokenLocks[_lockToken][lock_id];
        require(
            lock_id == _lock_id && userLock.owner == msg.sender,
            "DLock: LOCK DOES NOT MATCH"
        );
        require(userLock.unlockDate < _unlock_date, "DLock: UNLOCK BEFORE");

        // check if fee is met
        uint256 ethFee = gFees.ethFee;
        require(msg.value == ethFee, "DLock: FEE NOT MET");
        if (ethFee > 0) {
            devaddr.transfer(ethFee);
        }

        userLock.unlockDate = _unlock_date;

        emit onRelock(_lockToken, userLock.amount);
    }

    /**
     * @notice withdraw a valid amount from a locked token
     */
    function withdraw(
        address _lockToken,
        uint256 _index,
        uint256 _lock_id,
        uint256 _amount
    ) external nonReentrant {
        require(_amount > 0, "DLock: ZERO WITHDRAWL NOT ALLOWED");
        uint256 lock_id = users[msg.sender].locksForToken[_lockToken][_index];
        TokenLock storage userLock = tokenLocks[_lockToken][lock_id];
        require(
            lock_id == _lock_id && userLock.owner == msg.sender,
            "DLock: LOCK DOES NOT MATCH"
        );
        require(
            userLock.unlockDate < block.timestamp,
            "DLock: UNLOCK DATE NOT DUE"
        );
        userLock.amount = userLock.amount.sub(_amount);

        // remove the user if all tokens are unlocked and withdrawn
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[
                _lockToken
            ];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();
            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_lockToken);
            }
        }

        TransferHelper.safeTransfer(_lockToken, msg.sender, _amount);
        emit onWithdraw(_lockToken, _amount);
    }

    /**
     * @notice increment the amount on an existing lock
     */
    function incrementLock(
        address _lockToken,
        uint256 _index,
        uint256 _lock_id,
        uint256 _amount
    ) external payable nonReentrant {
        require(_amount > 0, "DLock: ZERO AMOUNT");
        uint256 lock_id = users[msg.sender].locksForToken[_lockToken][_index];
        TokenLock storage userLock = tokenLocks[_lockToken][lock_id];
        require(
            lock_id == _lock_id && userLock.owner == msg.sender,
            "DLock: LOCK DOES NOT MATCH"
        );

        TransferHelper.safeTransferFrom(
            _lockToken,
            address(msg.sender),
            address(this),
            _amount
        );

        // check if fee is met
        uint256 ethFee = gFees.ethFee;
        require(msg.value == ethFee, "DLock: FEE NOT MET");
        if (ethFee > 0) {
            devaddr.transfer(ethFee);
        }
        
        userLock.amount = userLock.amount.add(_amount);

        emit onDeposit(
            _lockToken,
            msg.sender,
            _amount,
            userLock.lockDate,
            userLock.unlockDate
        );
    }

    /**
     * @notice transfer ownership of locked tokens to another user
     */
    function transferLockOwnership(
        address _lockToken,
        uint256 _index,
        uint256 _lock_id,
        address payable _new_owner
    ) external {
        require(msg.sender != _new_owner, "Dlock: YOU ARE ALREADY THE OWNER");
        uint256 lock_id = users[msg.sender].locksForToken[_lockToken][_index];
        TokenLock storage transferredLock = tokenLocks[_lockToken][lock_id];
        require(
            lock_id == _lock_id && transferredLock.owner == msg.sender,
            "DLock: LOCK DOES NOT MATCH"
        ); // ensures correct lock is affected

        // store record for new lock owner
        UserInfo storage user = users[_new_owner];
        user.lockedTokens.add(_lockToken);
        uint256[] storage user_locks = user.locksForToken[_lockToken];
        user_locks.push(transferredLock.lockID);

        // store record for removing old lock owner
        uint256[] storage userLocks = users[msg.sender].locksForToken[
            _lockToken
        ];
        userLocks[_index] = userLocks[userLocks.length - 1];
        userLocks.pop();
        if (userLocks.length == 0) {
            users[msg.sender].lockedTokens.remove(_lockToken);
        }
        transferredLock.owner = _new_owner;

        emit onTranferLockOwnership(_lockToken, msg.sender, _new_owner);
    }

    function getTotalLocksForToken(address _lockToken)
        external
        view
        returns (uint256)
    {
        return tokenLocks[_lockToken].length;
    }

    function getLocksByTokenAddress(address _lockToken)
        external
        view
        returns (TokenLock[] memory)
    {
        return tokenLocks[_lockToken];
    }

    function getLocksByTokenAddressAndId(address _lockToken, uint256 _id)
        external
        view
        returns (TokenLock memory)
    {
        return tokenLocks[_lockToken][_id];
    }

    function getTotalLockedTokens() external view returns (uint256) {
        return lockedTokens.length();
    }

    function getLockedTokenAt(uint256 _index) external view returns (address) {
        return lockedTokens.at(_index);
    }

    function getUserTotalLockedTokens(address _user)
        external
        view
        returns (uint256)
    {
        UserInfo storage user = users[_user];
        return user.lockedTokens.length();
    }

    function getUserLockedTokenAt(address _user, uint256 _index)
        external
        view
        returns (address)
    {
        UserInfo storage user = users[_user];
        return user.lockedTokens.at(_index);
    }

    function getUserTotalLocksForToken(address _user, address _lockToken)
        external
        view
        returns (uint256)
    {
        UserInfo storage user = users[_user];
        return user.locksForToken[_lockToken].length;
    }

    function getUserFull(address _user)
        external
        view
        returns (address[] memory)
    {
        UserInfo storage user = users[_user];
        return user.lockedTokens.values();
    }

    function getAllLockAddresses() external view returns (address[] memory) {
        return lockedTokens.values();
    }

    function getUserLockForTokenAt(
        address _user,
        address _lockToken,
        uint256 _index
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            address
        )
    {
        uint256 lockID = users[_user].locksForToken[_lockToken][_index];
        TokenLock storage tokenLock = tokenLocks[_lockToken][lockID];
        return (
            tokenLock.lockDate,
            tokenLock.amount,
            tokenLock.initialAmount,
            tokenLock.unlockDate,
            tokenLock.lockID,
            tokenLock.owner
        );
    }
}
