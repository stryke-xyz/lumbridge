// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGaugeController, PullParams} from "../interfaces/IGaugeController.sol";

contract GaugeType1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20Metadata;

    uint8 public gaugeType = 1;

    IGaugeController public gaugeController;

    IERC20Metadata public syk;

    mapping(address => bool) public bridgeAdapters;

    event BridgeAdapterUpdated(address bridgeAdapter, bool add);

    error BridgeAdapterNotFound();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _initialOwner, address _gaugeController, address _syk) public initializer {
        gaugeController = IGaugeController(_gaugeController);
        syk = IERC20Metadata(_syk);

        __Ownable_init(_initialOwner);
        __UUPSUpgradeable_init();
    }

    function updateBridgeAdapter(address _bridgeAdapter, bool _add) external onlyOwner {
        bridgeAdapters[_bridgeAdapter] = _add;

        emit BridgeAdapterUpdated(_bridgeAdapter, _add);
    }

    // Applicable only to gauges live on arbitrum
    function pull(uint256 _epoch) external onlyOwner {
        PullParams memory pullParams = PullParams({
            epoch: _epoch,
            gaugeId: keccak256(abi.encode(block.chainid, address(this))),
            gaugeAddress: address(this)
        });

        gaugeController.pull(pullParams);

        IERC20Metadata(syk).safeTransfer(msg.sender, syk.balanceOf(address(this)));
    }

    // Applicable only to gauges live on any other chain than arbitrum (the initial call to pull SYK from arbitrum has to be called on the GaugeControllerAdapter)
    function pull() external onlyOwner {
        IERC20Metadata(syk).safeTransfer(msg.sender, syk.balanceOf(address(this)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
