// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

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

contract ArbiCryptLocker is Context, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Arbicrypt locker address
    address public _arbicryptLockerAddress = address(this);

    IUniFactory public uniswapFactory;

    // TokenLocker objct contains all locked token enteries and information
    struct TokenLockerObject {
        address tokenAddress;
        address withdrawalAddress;
        uint256 tokenAmount;
        uint256 unlockTime;
        uint256 lockDate;
        uint256 lockType; // 1 = UniV2 token lock, 2 = Token lock
        bool withdrawn;
    }

    // Key vars and data containers
    uint256 public depositId;
    uint256[] public allDepositIds;
    mapping(address => uint256[]) public depositsByWithdrawalAddress;
    mapping(address => uint256[]) public depositsByTokenAddress;
    mapping(uint256 => TokenLockerObject) public lockedToken;
    mapping(address => mapping(address => uint256)) public walletTokenBalance;

    /**
     *Event for tokens being withdrawn to its owner after time lock complete and withdrawal requested
     */
    event LogWithdrawal(address SentToAddress, uint256 AmountTransferred);

    /**
     *Event for tokens being locked
     */
    event LogLock(
        uint256 _id,
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _amount,
        uint256 _unlockTime,
        uint256 _lockDate,
        uint256 _lockType,
        bool _withdrawn
    );

    constructor(IUniFactory _uniswapFactory) {
        uniswapFactory = _uniswapFactory;
    }

    /**
     *lock tokens
     */
    function lockTokens(
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _amount,
        uint256 _unlockTime,
        uint256 _lockType
    ) public returns (uint256 _id) {
        require(_lockType > 0, "TIMESTAMP INVALID");
        require(
            _amount > 0,
            "ArbiCryptLocker: amount of tokens requested to lock is 0"
        );

        if (_lockType == 1) {
            // ensure this pair is a univ2 pair by querying the factory
            IUniswapV2Pair lpair = IUniswapV2Pair(address(_tokenAddress));
            address factoryPairAddress = uniswapFactory.getPair(
                lpair.token0(),
                lpair.token1()
            );
            require(factoryPairAddress == address(_tokenAddress), "NOT UNIV2");
        }

        // take fess here ? wait on team

        //update balance in address
        walletTokenBalance[_tokenAddress][
            _withdrawalAddress
        ] = walletTokenBalance[_tokenAddress][_withdrawalAddress].add(_amount);

        _id = ++depositId;
        lockedToken[_id].tokenAddress = _tokenAddress;
        lockedToken[_id].withdrawalAddress = _withdrawalAddress;
        lockedToken[_id].tokenAmount = _amount;
        lockedToken[_id].unlockTime = _unlockTime;
        lockedToken[_id].lockDate = block.timestamp;
        lockedToken[_id].lockType = _lockType;
        lockedToken[_id].withdrawn = false;

        allDepositIds.push(_id);
        depositsByWithdrawalAddress[_withdrawalAddress].push(_id);
        depositsByTokenAddress[_tokenAddress].push(_id);

        // transfer tokens into contract
        require(
            IERC20(_tokenAddress).transferFrom(
                msg.sender,
                _arbicryptLockerAddress,
                _amount
            ),
            "ArbiCryptLocker: transfer failed"
        );

        emit LogLock(
            _id,
            _tokenAddress,
            _withdrawalAddress,
            _amount,
            _unlockTime,
            lockedToken[_id].lockDate,
            _lockType,
            lockedToken[_id].withdrawn
        );
    }

    /**
     *Create multiple locks
     */
    function createMultipleLocks(
        address _tokenAddress,
        address _withdrawalAddress,
        uint256 _lockType,
        uint256[] memory _amounts,
        uint256[] memory _unlockTimes
    ) public returns (uint256 _id) {
        require(_amounts.length > 0, "ArbiCryptLocker: Amount is less than 0");
        require(
            _amounts.length == _unlockTimes.length,
            "ArbiCryptLocker: Amounts and unlock count dont match"
        );

        if (_lockType == 1) {
            // ensure this pair is a univ2 pair by querying the factory
            IUniswapV2Pair lpair = IUniswapV2Pair(address(_tokenAddress));
            address factoryPairAddress = uniswapFactory.getPair(
                lpair.token0(),
                lpair.token1()
            );
            require(factoryPairAddress == address(_tokenAddress), "NOT UNIV2");
        }

        uint256 i;
        for (i = 0; i < _amounts.length; i++) {
            require(_amounts[i] > 0);

            //update balance in address
            walletTokenBalance[_tokenAddress][
                _withdrawalAddress
            ] = walletTokenBalance[_tokenAddress][_withdrawalAddress].add(
                _amounts[i]
            );

            _id = ++depositId;
            lockedToken[_id].tokenAddress = _tokenAddress;
            lockedToken[_id].withdrawalAddress = _withdrawalAddress;
            lockedToken[_id].tokenAmount = _amounts[i];
            lockedToken[_id].unlockTime = _unlockTimes[i];
            lockedToken[_id].lockDate = block.timestamp;
            lockedToken[_id].lockType = _lockType;
            lockedToken[_id].withdrawn = false;

            allDepositIds.push(_id);
            depositsByWithdrawalAddress[_withdrawalAddress].push(_id);
            depositsByTokenAddress[_tokenAddress].push(_id);

            //transfer tokens into contract
            require(
                IERC20(_tokenAddress).transferFrom(
                    msg.sender,
                    _tokenAddress,
                    _amounts[i]
                ),
                "ArbiCryptLocker: transfer failed"
            );
        }
    }

    /**
     *Extend lock Duration
     */
    function extendLockDuration(uint256 _id, uint256 _unlockTime) public {
        require(
            _unlockTime < 10000000000,
            "ArbiCryptLocker: new unlock time is too small"
        );
        require(
            _unlockTime > lockedToken[_id].unlockTime,
            "ArbiCryptLocker: unlock time is before current unlock time"
        );
        require(
            !lockedToken[_id].withdrawn,
            "ArbiCryptLocker: tokens have already been withdrawn"
        );
        require(
            msg.sender == lockedToken[_id].withdrawalAddress,
            "ArbiCryptLocker: you don't own this lock"
        );

        //set new unlock time
        lockedToken[_id].unlockTime = _unlockTime;
    }

    /**
     *transfer locked tokens
     */
    function transferLocks(uint256 _id, address _receiverAddress) public {
        require(
            !lockedToken[_id].withdrawn,
            "ArbiCryptLocker: token have already been withdrawn"
        );
        require(
            msg.sender == lockedToken[_id].withdrawalAddress,
            "ArbiCryptLocker: you don't own this lock"
        );

        //decrease sender's token balance
        walletTokenBalance[lockedToken[_id].tokenAddress][
            msg.sender
        ] = walletTokenBalance[lockedToken[_id].tokenAddress][msg.sender].sub(
            lockedToken[_id].tokenAmount
        );

        //increase receiver's token balance
        walletTokenBalance[lockedToken[_id].tokenAddress][
            _receiverAddress
        ] = walletTokenBalance[lockedToken[_id].tokenAddress][_receiverAddress]
            .add(lockedToken[_id].tokenAmount);

        //remove this id from sender address
        uint256 j;
        uint256 arrLength = depositsByWithdrawalAddress[
            lockedToken[_id].withdrawalAddress
        ].length;
        for (j = 0; j < arrLength; j++) {
            if (
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress][
                    j
                ] == _id
            ) {
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress][
                    j
                ] = depositsByWithdrawalAddress[
                    lockedToken[_id].withdrawalAddress
                ][arrLength - 1];
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress]
                    .pop();
                break;
            }
        }

        //Assign this id to receiver address
        lockedToken[_id].withdrawalAddress = _receiverAddress;
        depositsByWithdrawalAddress[_receiverAddress].push(_id);
    }

    /**
     *withdraw tokens
     */
    function withdrawTokens(uint256 _id) public {
        require(
            lockedToken[_id].unlockTime < block.timestamp,
            "ArbiCryptLocker: Can only be widthrawn on specified unlock time"
        );
        require(
            msg.sender == lockedToken[_id].withdrawalAddress,
            "ArbiCryptLocker: you don't own this lock"
        );
        require(
            !lockedToken[_id].withdrawn,
            "ArbiCryptLocker: token have already been withdrawn"
        );

        lockedToken[_id].withdrawn = true;

        //update balance in address
        walletTokenBalance[lockedToken[_id].tokenAddress][
            msg.sender
        ] = walletTokenBalance[lockedToken[_id].tokenAddress][msg.sender].sub(
            lockedToken[_id].tokenAmount
        );

        //remove this id from this address
        uint256 j;
        uint256 arrLength = depositsByWithdrawalAddress[
            lockedToken[_id].withdrawalAddress
        ].length;
        for (j = 0; j < arrLength; j++) {
            if (
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress][
                    j
                ] == _id
            ) {
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress][
                    j
                ] = depositsByWithdrawalAddress[
                    lockedToken[_id].withdrawalAddress
                ][arrLength - 1];
                depositsByWithdrawalAddress[lockedToken[_id].withdrawalAddress]
                    .pop();
                break;
            }
        }

        // transfer tokens to wallet address
        require(
            IERC20(lockedToken[_id].tokenAddress).transfer(
                msg.sender,
                lockedToken[_id].tokenAmount
            )
        );
        emit LogWithdrawal(msg.sender, lockedToken[_id].tokenAmount);
    }

    /*get total token balance in contract*/
    function getTotalTokenBalance(address _tokenAddress)
        public
        view
        returns (uint256)
    {
        return IERC20(_tokenAddress).balanceOf(_arbicryptLockerAddress);
    }

    /*get total token balance by address*/
    function getTokenBalanceByAddress(
        address _tokenAddress,
        address _walletAddress
    ) public view returns (uint256) {
        return walletTokenBalance[_tokenAddress][_walletAddress];
    }

    /*get allDepositIds*/
    function getAllDepositIds() public view returns (uint256[] memory) {
        return allDepositIds;
    }

    /*get getDepositDetails by Id*/
    function getDepositDetailsById(uint256 _id)
        public
        view
        returns (
            address _tokenAddress,
            address _withdrawalAddress,
            uint256 _tokenAmount,
            uint256 _unlockTime,
            uint256 _lockDate,
            uint256 _lockType,
            bool _withdrawn
        )
    {
        return (
            lockedToken[_id].tokenAddress,
            lockedToken[_id].withdrawalAddress,
            lockedToken[_id].tokenAmount,
            lockedToken[_id].unlockTime,
            lockedToken[_id].lockDate,
            lockedToken[_id].lockType,
            lockedToken[_id].withdrawn
        );
    }

    /* returns details of first active lock for the given token address*/
    function getDepositDetailsByAddress(address _tokenAddress)
        public
        view
        returns (
            address _tokenAddress_,
            address _withdrawalAddress,
            uint256 _tokenAmount,
            uint256 _unlockTime,
            uint256 _lockDate,
            uint256 _lockType,
            bool _withdrawn
        )
    {
        uint256 oldestId = depositsByTokenAddress[_tokenAddress][0];

        return (
            lockedToken[oldestId].tokenAddress,
            lockedToken[oldestId].withdrawalAddress,
            lockedToken[oldestId].tokenAmount,
            lockedToken[oldestId].unlockTime,
            lockedToken[oldestId].lockDate,
            lockedToken[oldestId].lockType,
            lockedToken[oldestId].withdrawn
        );
    }

    /* get total number of locks */
    function getTotalLockedTokens() external view returns (uint256) {
        return allDepositIds.length;
    }

    /* get total number of locks by withdrawal address*/
    function getTotalLockedTokensByWithdrawalAddress(address _withdrawalAddress)
        external
        view
        returns (uint256)
    {
        return depositsByWithdrawalAddress[_withdrawalAddress].length;
    }

    /* get total number of locks by token address*/
    function getTotalLockedTokensByTokenAddress(address _tokenAddress)
        external
        view
        returns (uint256)
    {
        return depositsByTokenAddress[_tokenAddress].length;
    }

    /*get DepositsByWithdrawalAddress This info is stored in the contract data on the blockchain and can be pulled by pulling the deposit ids from the stored data by deposit ID*/
    function getDepositsByWithdrawalAddress(address _withdrawalAddress)
        public
        view
        returns (uint256[] memory)
    {
        return depositsByWithdrawalAddress[_withdrawalAddress];
    }

    /*get deposit by token address */
    function getDepositsByTokenAddress(address _tokenAddress)
        public
        view
        returns (uint256[] memory)
    {
        return depositsByTokenAddress[_tokenAddress];
    }
}

