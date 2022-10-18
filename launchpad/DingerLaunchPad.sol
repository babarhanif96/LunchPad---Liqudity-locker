pragma solidity ^0.8.10;
// SPDX-License-Identifier: UNLICENSED

// Contract by CryptoJames
// Telegram & Twitter @cryptojames98

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DingerLaunchPad is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

     struct CrowdsaleObject {
        uint256 rate;
        address tokenOwnerAddress;
        address payable receivingWalletAddress;
        ERC20 token;
        uint256 cap;
        uint256 openingTime;
        uint256 closingTime;
        bool whitelistable;
        bool trackContributions;
        uint256 investorMinCap;
        uint256 investorHardCap;
        uint256 crowdsaleTokenSupply;
        uint256 weiRaised;
        bool finalized;
        mapping(address => bool) whitelist;
        mapping(address => uint256) contributions;
        mapping(address => uint256) tokenBalances; 
    }

    struct CrowdsaleObjectExtension {
        uint256 goal;
        bool refundable;
        bool remainingTokensClaimed;
        bool ethProceedsClaimed;
        mapping(address => bool) claimed;
    }

    uint256 public crowdsaleId;
    uint256[] public allCrowdsaleIds;
    mapping (uint256 => CrowdsaleObject) public crowdsales;
    mapping (uint256 => CrowdsaleObjectExtension) public crowdsalesExtension;
    mapping (address => uint256[]) public crowdsalesByOwnerAddress;
    

    event TokensPurchased(uint256 indexed _id, address indexed purchaser, uint256 value, uint256 amount, uint256 weiRaised);
    event CrowdsaleExtended(uint256 indexed _id, uint256 prevClosingTime, uint256 newClosingTime);
    event CrowdsaleFinalized(uint256 indexed _id);
    event LogCrowdsale(uint256 indexed _id, bool[3] _features);
    event TokensClaimed(uint256 indexed _id, address indexed claimer, uint256 amount);
    event RefundClaimed(uint256 indexed _id, address indexed claimer, uint256 value);
    event RemainingTokensClaimed(uint256 indexed _id, address indexed claimer, uint256 value);
    event ETHProeedsWithdrawn(uint256 indexed _id, address indexed claimer, uint256 value);

    function createCrowdsale(
        uint256 _rate,
        address payable _receivingWalletAddress,
        ERC20 _token,
        uint256 _openingTime,
        uint256 _closingTime,
        uint256 _crowdsaleTokenSupply,
        uint256 _investorMinCap,
        uint256 _investorHardCap,
        uint256 _goal,
        bool[3] memory _features
    ) external returns (uint256 _id) {
        
        uint256 _cap = _crowdsaleTokenSupply.mul(1e18).div(_rate.mul(10 ** _token.decimals()));
        bool _whitelistable = _features[0];
        bool _trackContributions = _features[1];
        bool _refundable = _features[2];

        require(_rate > 0, "Rate is 0");
        require(_receivingWalletAddress != address(0), "Receiving wallet is the zero address");
        require(address(_token) != address(0), "Token is the zero address");
        require(_cap > 0, "Cap is 0");
        require(_openingTime >= block.timestamp, "Opening time is before current time");
        require(_closingTime > _openingTime, "Opening time is not before closing time");

        if (_refundable) {
            require(_goal > 0, "Goal is 0");
            require(_cap >= _goal, "Cap must be more than goal. Check token supply & rate");
        }
        
        
        if (_trackContributions) {
            require(_investorHardCap > 0 && _investorMinCap > 0 && _investorHardCap > _investorMinCap , "Investor contribution cap 0 or mismatch");
        }

        _id = ++crowdsaleId;        
        crowdsales[_id].rate = _rate;
        crowdsales[_id].tokenOwnerAddress = msg.sender;
        crowdsales[_id].receivingWalletAddress = _receivingWalletAddress;
        crowdsales[_id].token = _token;
        crowdsales[_id].cap = _cap;
        crowdsales[_id].openingTime = _openingTime;
        crowdsales[_id].closingTime = _closingTime;
        crowdsales[_id].whitelistable = _whitelistable;
        crowdsales[_id].trackContributions = _trackContributions;
        crowdsales[_id].investorMinCap = _investorMinCap;
        crowdsales[_id].investorHardCap = _investorHardCap;
        crowdsales[_id].crowdsaleTokenSupply = _crowdsaleTokenSupply;
        crowdsales[_id].finalized = false;
        crowdsalesExtension[_id].refundable = _refundable;
        crowdsalesExtension[_id].goal = _goal;

        if (_whitelistable) {
            crowdsales[_id].whitelist[msg.sender] = true;
        }        

        crowdsales[_id].token.transferFrom(msg.sender, address(this), _crowdsaleTokenSupply);

        allCrowdsaleIds.push(_id);
        crowdsalesByOwnerAddress[msg.sender].push(_id);

        emit LogCrowdsale(_id, [_whitelistable, _trackContributions, _refundable]);
    }

    function token(uint256 _id) external view returns (ERC20) {
        return crowdsales[_id].token;
    }

    function receivingWalletAddress(uint256 _id) external view returns (address payable) {
        return crowdsales[_id].receivingWalletAddress;
    }

    function rate(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].rate;
    }

    function weiRaised(uint256 _id) public view returns (uint256) {
        return crowdsales[_id].weiRaised;
    }

    receive() external payable {}

    function buyTokens(uint256 _id) external nonReentrant payable {
        uint256 _weiAmount = msg.value;
        _preValidatePurchase(_id, _weiAmount);

        // calculate token amount to be created
        uint256 _tokens = _getTokenAmount(_id, _weiAmount);

        if (!crowdsalesExtension[_id].refundable) {
            _processPurchase(_id, _tokens);
        }

        _updatePurchasingState(_id, _weiAmount, _tokens);

        emit TokensPurchased(_id, msg.sender, _weiAmount, _tokens, crowdsales[_id].weiRaised);

        if (!crowdsalesExtension[_id].refundable) {
            _forwardFunds(crowdsales[_id].receivingWalletAddress, _weiAmount);
        }
    }

    function _preValidatePurchase(uint256 _id, uint256 _weiAmount) internal view {
        require(msg.sender != address(0), "Crowdsale: beneficiary is the zero address");
        require(_weiAmount != 0, "Crowdsale: weiAmount is 0");
        require(isOpen(_id), "Crowdsale: Crowdsale is either closed or has not being opened yet. Thus, no purchasing allowed at this moment.");
        if (crowdsales[_id].whitelistable) {
            require(crowdsales[_id].whitelist[msg.sender], "Crowdsale: purchaser address not whitelisted to participate in this crowdsale");
        }
        if (crowdsales[_id].trackContributions) {
            uint256 _newContribution = crowdsales[_id].contributions[msg.sender].add(_weiAmount);
            require(_newContribution >= crowdsales[_id].investorMinCap && _newContribution <= crowdsales[_id].investorHardCap, "Purchase breaks investor soft or hard cap rules");
        }
        require(weiRaised(_id).add(_weiAmount) <= crowdsales[_id].cap, "Crowdsale:Capped cap exceeded");
    }

    function _deliverTokens(uint256 _id, uint256 _tokenAmount) internal {
        crowdsales[_id].token.transfer(msg.sender, _tokenAmount);
    }

    function _processPurchase(uint256 _id, uint256 _tokenAmount) internal {
        _deliverTokens(_id, _tokenAmount);
    }

    function _updatePurchasingState(uint256 _id, uint256 _weiAmount, uint256 _tokens) internal {
        crowdsales[_id].contributions[msg.sender] = crowdsales[_id].contributions[msg.sender] + _weiAmount;
        crowdsales[_id].weiRaised = crowdsales[_id].weiRaised.add(_weiAmount);
        crowdsales[_id].tokenBalances[msg.sender] = crowdsales[_id].tokenBalances[msg.sender].add(_tokens);
    }

    function _getTokenAmount(uint256 _id, uint256 _weiAmount) internal view returns (uint256) {
        return _weiAmount.mul(crowdsales[_id].rate).mul(10 ** crowdsales[_id].token.decimals()).div(1e18);
    }

    function _forwardFunds(address _beneficiary, uint256 value) internal {
        payable(_beneficiary).transfer(value);
    }

    function cap(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].cap;
    }

    function capReached(uint256 _id) external view returns (bool) {
        return weiRaised(_id) >= crowdsales[_id].cap;
    }

    function goalReached(uint256 _id) public view returns (bool) {
        return weiRaised(_id) >= crowdsalesExtension[_id].goal;
    }

    function openingTime(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].openingTime;
    }

    function closingTime(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].closingTime;
    }

    function isOpen(uint256 _id) public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp >= crowdsales[_id].openingTime && block.timestamp <= crowdsales[_id].closingTime;
    }

    function hasClosed(uint256 _id) public view returns (bool) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp > crowdsales[_id].closingTime;
    }

    function extendTime(uint256 _id, uint256 newClosingTime) external {
        require(crowdsales[_id].tokenOwnerAddress == msg.sender, "Crowdsale: Only owner can extend the closing time");
        require(!hasClosed(_id), "Crowdsale: already closed");
        // solhint-disable-next-line max-line-length
        require(newClosingTime > crowdsales[_id].closingTime, "Crowdsale: new closing time is before current closing time");

        crowdsales[_id].closingTime = newClosingTime;
        emit CrowdsaleExtended(_id, crowdsales[_id].closingTime, newClosingTime);
    }

    function getUserETHContribution(uint256 _id, address _beneficiary) external view returns (uint256) {
        return crowdsales[_id].contributions[_beneficiary];
    }

    function getUserTokenContribution(uint256 _id, address _beneficiary) external view returns (uint256) {
        return crowdsales[_id].tokenBalances[_beneficiary];
    }

    function checkIfUserIsWhitelisted(uint256 _id, address _userAddress) external view returns (bool) {
        if (!crowdsales[_id].whitelistable) {
            return true;
        } else {
            return crowdsales[_id].whitelist[_userAddress];
        }
    }

    function grantManyWhitelistRoles(uint256 _id, address[] memory _accounts) external {
        require(crowdsales[_id].tokenOwnerAddress == msg.sender, "Crowdsale: Only owner can grant whitelist previleges");
        if (crowdsales[_id].whitelistable) {
            for (uint256 i = 0; i < _accounts.length; i++) {
                crowdsales[_id].whitelist[_accounts[i]] = true;
            }
        }
    }

    function getInvestorMinimumCap(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].investorMinCap;
    }

    function getInvestorMaximumCap(uint256 _id) external view returns (uint256) {
        return crowdsales[_id].investorHardCap;
    }

    function isPrivate(uint256 _id) external view returns (bool) {
        return crowdsales[_id].whitelistable;
    }

    function isRefundable(uint256 _id) external view returns (bool) {
        return crowdsalesExtension[_id].refundable;
    }

    function getAllCrowdsaleIds() external view returns (uint256[] memory) {
        return allCrowdsaleIds;
    }

    function getCrowdsaleDetailsPartA(uint256 _id) external view returns (uint256 _rate, uint256 _cap, uint256 _weiRaised, uint256 _openingTime, uint256 _closingTime, uint256 _remainingTokenSupply) {
        uint256 remainingTokenAmount = _getTokenAmount(_id, crowdsales[_id].cap.sub(crowdsales[_id].weiRaised));
        return (
            crowdsales[_id].rate,
            crowdsales[_id].cap,
            crowdsales[_id].weiRaised,
            crowdsales[_id].openingTime,
            crowdsales[_id].closingTime,
            remainingTokenAmount
        );
    }

    function getCrowdsaleDetailsPartB(uint256 _id) external view returns ( bool _whitelistable, bool _trackContributions, uint256 _investorMinCap, uint256 _investorHardCap, address _tokenOwnerAddress, address _receivingWalletAddress, address _token) {
        return (
            crowdsales[_id].whitelistable,
            crowdsales[_id].trackContributions,
            crowdsales[_id].investorMinCap,
            crowdsales[_id].investorHardCap,
            crowdsales[_id].tokenOwnerAddress,
            crowdsales[_id].receivingWalletAddress,
            address(crowdsales[_id].token)
        );
    }

    function getCrowdsaleDetailsPartC(uint256 _id) external view returns (uint256 _crowdsaleTokenSupply, uint256 _goal, bool _refundable, bool _remainingTokensClaimed, bool _finalized) {
        return (
            crowdsales[_id].crowdsaleTokenSupply,
            crowdsalesExtension[_id].goal,
            crowdsalesExtension[_id].refundable,
            crowdsalesExtension[_id].remainingTokensClaimed,
            crowdsales[_id].finalized
        );
    }

    function getCrowdsalesByOwnerAddress(address _ownerAddress) external view returns (uint256[] memory) {
        return crowdsalesByOwnerAddress[_ownerAddress];
    }

    function isFinalized(uint256 _id) external view returns (bool) {
        return crowdsales[_id].finalized;
    }

    function hasUserClaimed(uint256 _id, address _userAddress) external view returns (bool) {
        return crowdsalesExtension[_id].claimed[_userAddress];
    }

    function finalize(uint256 _id) external {
        require(crowdsales[_id].tokenOwnerAddress == msg.sender || msg.sender == owner(), "Only owner can finalize the crowdsale");
        require(!crowdsales[_id].finalized, "Crowdsale already finalized");
        require(hasClosed(_id), "Crowdsale not closed");

        crowdsales[_id].finalized = true;
        emit CrowdsaleFinalized(_id);
    }

    function withdrawRemainingTokens(uint256 _id) external nonReentrant {
        require(crowdsales[_id].tokenOwnerAddress == msg.sender, "Only owner can withdraw tks");
        require(!crowdsalesExtension[_id].remainingTokensClaimed,  "Remaining Tokens already claimed");
        require(crowdsales[_id].finalized,  "Crowdsale not finalized yet");

        uint256 amount = _getTokenAmount(_id, crowdsales[_id].cap.sub(crowdsales[_id].weiRaised));

        if (crowdsalesExtension[_id].refundable && !goalReached(_id)) {
            amount = _getTokenAmount(_id, crowdsales[_id].cap);
        }

        crowdsalesExtension[_id].remainingTokensClaimed = true;
        emit RemainingTokensClaimed(_id, msg.sender, amount);
        _deliverTokens(_id, amount);
    }

    function withdrawETHProceeds(uint256 _id) external nonReentrant {
        require(crowdsales[_id].tokenOwnerAddress == msg.sender, "Only owner can withdraw tks");
        require(!crowdsalesExtension[_id].ethProceedsClaimed,  "Proceeds already claimed");
        require(crowdsales[_id].finalized,  "Crowdsale not finalized yet");
        require(crowdsalesExtension[_id].refundable, "Can only claim tokens for refundable crowdsales");
        require(goalReached(_id),  "Goal not reached. Cannot claim proceeds");

        crowdsalesExtension[_id].ethProceedsClaimed = true;
        emit ETHProeedsWithdrawn(_id, msg.sender, weiRaised(_id));
        _forwardFunds(msg.sender, weiRaised(_id));
    }

    function claimTokens(uint256 _id) external nonReentrant {
        require(crowdsales[_id].finalized,  "Crowdsale not finalized yet");
        require(crowdsalesExtension[_id].refundable, "Can only claim tokens for refundable crowdsales");
        require(goalReached(_id),  "Goal not reached. Claim refund instead");
        require(!crowdsalesExtension[_id].claimed[msg.sender], "Already claimed");
        require(crowdsales[_id].tokenBalances[msg.sender] > 0, "Not eligible to claim");

        uint256 amount = crowdsales[_id].tokenBalances[msg.sender];
        crowdsalesExtension[_id].claimed[msg.sender] = true;

        emit TokensClaimed(_id, msg.sender, amount);
        _deliverTokens(_id, amount);
    }

    function claimRefund(uint256 _id) external nonReentrant {
        require(crowdsales[_id].finalized,  "Crowdsale not finalized yet");
        require(crowdsalesExtension[_id].refundable, "Can only claim refund for refundable crowdsales");
        require(!goalReached(_id),  "Goal reached. Claim tokens instead");
        require(!crowdsalesExtension[_id].claimed[msg.sender], "Already claimed");
        require(crowdsales[_id].contributions[msg.sender] > 0, "Not eligible to claim");

        uint256 value = crowdsales[_id].contributions[msg.sender];
        crowdsalesExtension[_id].claimed[msg.sender] = true;

        emit RefundClaimed(_id, msg.sender, value);
        _forwardFunds(msg.sender, value);    
    }
}