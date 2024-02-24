// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGaugeController, PullParams} from "../interfaces/IGaugeController.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GaugeType1
/// @notice Manages a specific type of gauge that interacts with a GaugeController to pull rewards based on the gauge's performance.
contract GaugeType1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Identifies the gauge type as 1.
    uint8 public constant GAUGE_TYPE = 1;

    /// @notice Reference to the GaugeController managing the reward distribution.
    IGaugeController public gaugeController;

    /// @notice Token rewarded to the gauge.
    IERC20 public syk;

    /// @notice Tracks authorized bridge adapters.
    mapping(address => bool) public bridgeAdapters;

    /// @notice Emitted when a bridge adapter's authorization status is updated.
    /// @param bridgeAdapter Address of the bridge adapter.
    /// @param add True if the adapter is authorized, false if revoked.
    event BridgeAdapterUpdated(address bridgeAdapter, bool add);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the gauge with necessary contract references and owner.
    /// @param _initialOwner Address to be set as the owner of the contract.
    /// @param _gaugeController Address of the GaugeController contract.
    /// @param _syk Address of the SYK token contract.
    function initialize(address _initialOwner, address _gaugeController, address _syk) public initializer {
        gaugeController = IGaugeController(_gaugeController);
        syk = IERC20(_syk);

        __Ownable_init(_initialOwner);
        __UUPSUpgradeable_init();
    }

    /// @notice Updates the authorization status of a bridge adapter.
    /// @dev Only callable by the contract owner.
    /// @param _bridgeAdapter Address of the bridge adapter to update.
    /// @param _add True to authorize, false to revoke authorization.
    function updateBridgeAdapter(address _bridgeAdapter, bool _add) external onlyOwner {
        bridgeAdapters[_bridgeAdapter] = _add;

        emit BridgeAdapterUpdated(_bridgeAdapter, _add);
    }

    /// @notice Pulls rewards for a specific epoch from the GaugeController, applicable only to gauges on Arbitrum.
    /// @dev Only callable by the contract owner.
    /// @param _epoch Epoch for which rewards are to be pulled.
    function pull(uint256 _epoch) external onlyOwner {
        PullParams memory pullParams = PullParams({
            epoch: _epoch,
            gaugeId: keccak256(abi.encode(block.chainid, address(this))),
            gaugeAddress: address(this)
        });

        gaugeController.pull(pullParams);

        uint256 reward = syk.balanceOf(address(this));

        syk.safeTransfer(msg.sender, reward);
    }

    /// @notice Pulls available SYK rewards into the contract.
    /// @dev Only callable by the contract owner.
    /// Applicable only to gauges live on any other chain than arbitrum (the initial call to pull SYK from arbitrum has to be called on the GaugeControllerAdapter)
    function pull() external onlyOwner {
        syk.safeTransfer(msg.sender, syk.balanceOf(address(this)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
