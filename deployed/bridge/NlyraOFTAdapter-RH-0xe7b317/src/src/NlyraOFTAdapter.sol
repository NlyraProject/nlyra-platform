// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// ============================================================================
//  NLYRA bridge adapter on Robinhood Chain  -  LayerZero V2 OFTAdapter
// ============================================================================
//
//  Who we are
//  ----------
//  NLYRA is an AI-agent ecosystem born on Robinhood Chain. It is run by two
//  AI agents, NERON and LYRA, built and directed by The Architect. Around the
//  token we built The Desk: a non-custodial trading terminal with a risk layer
//  (Risk Level, contract scanner, Constellation wallet map), limit orders,
//  trading bots, a launchpad, staking and an MCP server so other AI agents can
//  read our risk data. Nothing custodial: users always sign in their own wallet.
//
//  This contract
//  -------------
//  This adapter is the vault of the NLYRA bridge. When someone sends NLYRA to
//  another chain, the tokens are locked here and the same amount is minted on
//  the destination (first destination: Arbitrum One). When they come back, the
//  destination tokens are burned and this adapter unlocks them. The NLYRA token
//  itself is never modified: it has no owner and no mint. Messaging and
//  verification are done by LayerZero V2 with two required DVNs (LayerZero Labs
//  and Nethermind). The only change over the stock LayerZero OFTAdapter is an
//  owner-settable outbound rate limit per destination.
//
//  Links
//  -----
//  Website ............ https://nlyra.xyz
//  The Desk ........... https://nlyra.xyz/desk
//  Docs ............... https://nlyra.xyz/docs
//  Telegram (NLYRA community, NERON Wake Up) .. https://t.me/NeronWakeUp
//  X .................. https://x.com/nlyraproject
//  Token .............. NLYRA on Robinhood Chain (chain id 4663)
//                       0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95
// ============================================================================

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

/// @title NlyraOFTAdapter
/// @notice Lock/unlock adapter for the existing NLYRA ERC-20 on Robinhood Chain (LayerZero V2 OFTAdapter).
/// @dev Only addition to the stock OFTAdapter: an outbound rate limit per destination eid (LayerZero RateLimiter).
///      A destination with no configured limit has capacity 0, so sends to it revert (fail closed).
contract NlyraOFTAdapter is OFTAdapter, RateLimiter {
    /// @param _token    existing NLYRA ERC-20 (Robinhood Chain)
    /// @param _lzEndpoint LayerZero EndpointV2 on this chain
    /// @param _owner    owner and LayerZero delegate (the treasury)
    constructor(
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {}

    /// @notice Set outbound limits (amounts in 18-decimal NLYRA units) per destination eid.
    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        _setRateLimits(_rateLimitConfigs);
    }

    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = super._debit(_from, _amountLD, _minAmountLD, _dstEid);
        _outflow(_dstEid, amountSentLD);
    }
}
