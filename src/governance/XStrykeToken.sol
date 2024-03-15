// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessManagedUpgradeable} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContractWhitelist} from "../helpers/ContractWhitelist.sol";

import {IStrykeTokenBase} from "../interfaces/IStrykeTokenBase.sol";
import {IXStrykeToken, VestData, VestStatus, RedeemSettings} from "../interfaces/IXStrykeToken.sol";

/// @title XStrykeToken
/// @author witherblock
/// @notice Implements token staking and vesting mechanisms with upgradeable contract features.
contract XStrykeToken is
    ContractWhitelist,
    IXStrykeToken,
    Initializable,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessManagedUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IStrykeTokenBase;

    /*==== STATE VARIABLES ====*/

    /// @notice Address of the underlying SYK token.
    IStrykeTokenBase public syk;

    address public excessReceiver;

    /// @notice Index to track the next vest entry.
    uint256 public vestIndex;

    /// @notice The maximum fixed ratio for redeeming xSYK for SYK tokens.
    uint256 public constant MAX_FIXED_RATIO = 100; // 100%

    /// @notice Tracks addresses eligible for specific contract interactions.
    mapping(address => bool) public whitelist;

    /// @notice Stores vesting data for each vest operation.
    mapping(uint256 => VestData) public vests;

    /// @notice Struct to store redeem settings including ratio and duration limits.
    RedeemSettings public redeemSettings;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with the SYK token address and AccessManager contract.
    /// @dev Sets initial redeem settings and marks the contract as initialized.
    /// @param _syk Address of the SYK token.
    /// @param _initialAuthority Address of the AccessManaged contract.
    function initialize(address _syk, address _initialAuthority) public initializer {
        syk = IStrykeTokenBase(_syk);
        redeemSettings = RedeemSettings({minRatio: 50, maxRatio: 100, minDuration: 7 days, maxDuration: 180 days});
        __AccessManaged_init(_initialAuthority);
        // Set this address to be in the whitelist
        whitelist[address(this)] = true;
        // Set the deployer as excess receiver
        excessReceiver = msg.sender;
    }

    /*==== RESTRICTED FUNCTIONS ====*/

    /// @dev Updates the excess Receiver. Can only be called by admin.
    /// @param _excessReceiver excess receiver address
    function updateExcessReceiver(address _excessReceiver) external restricted {
        excessReceiver = _excessReceiver;

        emit ExcessReceiverUpdated(_excessReceiver);
    }

    /// @dev Updates the redeem settings. Can only be called by admin.
    /// @param _redeemSettings RedeemSettings struct
    function updateRedeemSettings(RedeemSettings memory _redeemSettings) external restricted {
        if ((_redeemSettings.minRatio > _redeemSettings.maxRatio) || (_redeemSettings.maxRatio > MAX_FIXED_RATIO)) {
            revert XStrykeToken_WrongRatioValues();
        }

        if (_redeemSettings.minDuration > _redeemSettings.maxDuration) revert XStrykeToken_WrongDurationValues();

        redeemSettings = _redeemSettings;

        emit RedeemSettingsUpdated(_redeemSettings);
    }

    /// @dev Updates the whitelist for transfers. Can only be called by admin.
    /// @param _account the address of the account
    /// @param _whitelisted whitelisted or not
    function updateWhitelist(address _account, bool _whitelisted) external restricted {
        if (_account == address(this)) revert XStrykeToken_InvalidWhitelistAddress();

        whitelist[_account] = _whitelisted;

        emit WhitelistUpdated(_account, _whitelisted);
    }

    /// @dev Update contract whitelist
    /// @param _contract the address of the contract to update the whitelist of
    /// @param _add boolean for adding or removing
    function updateContractWhitelist(address _contract, bool _add) public override(ContractWhitelist) restricted {
        super.updateContractWhitelist(_contract, _add);
    }

    /*==== VIEWS ====*/

    /// @dev Computes the redeemable SYK for "amount" of xSYK vested for "duration" seconds
    /// @param _xSykAmount amount of xSYK
    /// @param _duration the duration of the vesting
    /// @return sykAmount
    function getSykByVestingDuration(uint256 _xSykAmount, uint256 _duration) public view returns (uint256) {
        if (_duration < redeemSettings.minDuration) {
            return 0;
        }

        if (_duration > redeemSettings.maxDuration) {
            return (_xSykAmount * redeemSettings.maxRatio) / 100;
        }

        uint256 ratio = redeemSettings.minRatio
            + (
                ((_duration - redeemSettings.minDuration) * (redeemSettings.maxRatio - redeemSettings.minRatio))
                    / (redeemSettings.maxDuration - redeemSettings.minDuration)
            );

        return (_xSykAmount * ratio) / 100;
    }

    /*==== PUBLIC FUNCTIONS ====*/

    /// @inheritdoc	IXStrykeToken
    function convert(uint256 _amount, address _to) external nonReentrant {
        _isEligibleSender();
        _convert(_amount, _to);
    }

    /// @inheritdoc	IXStrykeToken
    function vest(uint256 _amount, uint256 _duration) external nonReentrant {
        if (_amount <= 0) revert XStrykeToken_AmountZero();
        if (_duration < redeemSettings.minDuration) revert XStrykeToken_DurationTooLow();

        _transfer(msg.sender, address(this), _amount);

        // get corresponding SYK amount
        uint256 sykAmount = getSykByVestingDuration(_amount, _duration);

        emit Vested(msg.sender, _amount, sykAmount, _duration, vestIndex);

        // if redeeming is not immediate, go through vesting process
        if (_duration > 0) {
            // add vesting entry
            vests[vestIndex] = VestData({
                account: msg.sender,
                sykAmount: sykAmount,
                xSykAmount: _amount,
                maturity: block.timestamp + _duration,
                status: VestStatus.ACTIVE
            });
            vestIndex += 1;
        } else {
            // immediately redeem for SYK
            _redeem(msg.sender, _amount, sykAmount);
        }
    }

    /// @inheritdoc	IXStrykeToken
    function redeem(uint256 _vestIndex) external nonReentrant {
        VestData storage _vest = vests[_vestIndex];
        if (_vest.account != msg.sender) revert XStrykeToken_SenderNotOwner();
        if (_vest.maturity > block.timestamp) revert XStrykeToken_VestingHasNotMatured();
        if (_vest.status != VestStatus.ACTIVE) revert XStrykeToken_VestingNotActive();

        _vest.status = VestStatus.REDEEMED;

        _redeem(msg.sender, _vest.xSykAmount, _vest.sykAmount);
    }

    /// @inheritdoc	IXStrykeToken
    function cancelVest(uint256 _vestIndex) external nonReentrant {
        VestData storage _vest = vests[_vestIndex];
        if (_vest.account != msg.sender) revert XStrykeToken_SenderNotOwner();
        if (_vest.status != VestStatus.ACTIVE) revert XStrykeToken_VestingNotActive();

        _vest.status = VestStatus.CANCELLED;

        _transfer(address(this), msg.sender, _vest.xSykAmount);

        emit VestCancelled(msg.sender, _vestIndex, _vest.xSykAmount);
    }

    /*==== INTERNAL FUNCTIONS ====*/

    function _convert(uint256 _amount, address _to) internal {
        if (_amount <= 0) revert XStrykeToken_AmountZero();

        syk.safeTransferFrom(msg.sender, address(this), _amount);

        // mint new xSYK
        _mint(_to, _amount);

        emit Converted(msg.sender, _to, _amount);
    }

    function _redeem(address _account, uint256 _xSykAmount, uint256 _sykAmount) internal {
        uint256 excess = _xSykAmount - _sykAmount;

        // Burn the xSYK
        _burn(address(this), _xSykAmount);

        syk.safeTransfer(_account, _sykAmount);

        // Transfer excess to the excess receiver
        syk.safeTransfer(excessReceiver, excess);

        emit Redeemed(_account, _xSykAmount, _sykAmount);
    }

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20PausableUpgradeable, ERC20Upgradeable)
    {
        bool condition = (from == address(0)) || whitelist[from] || whitelist[to];

        if (!condition) revert XStrykeToken_TransferNotAllowed();

        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}
}
