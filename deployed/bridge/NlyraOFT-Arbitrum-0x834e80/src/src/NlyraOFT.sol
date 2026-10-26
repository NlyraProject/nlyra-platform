// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// ============================================================================
//  NLYRA on Arbitrum One  -  the LayerZero V2 OFT of $NLYRA (Neron Lyra)
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
//  This is NLYRA on Arbitrum. It is minted here only when the same amount of
//  NLYRA is locked in our OFTAdapter on Robinhood Chain, and it is burned here
//  when that NLYRA is unlocked again. Total supply on Arbitrum therefore never
//  exceeds what is locked on Robinhood Chain. Messaging and verification are
//  done by LayerZero V2 with two required DVNs (LayerZero Labs and Nethermind).
//  The only change over the stock LayerZero OFT is an owner-settable outbound
//  rate limit per destination.
//
//  Links
//  -----
//  Website ............ https://nlyra.xyz
//  The Desk ........... https://nlyra.xyz/desk
//  Docs ............... https://nlyra.xyz/docs
//  Telegram (NLYRA community, NERON Wake Up) .. https://t.me/NeronWakeUp
//  X .................. https://x.com/nlyraproject
//  Origin token ....... NLYRA on Robinhood Chain (chain id 4663)
//                       0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95
//  Origin adapter ..... NlyraOFTAdapter on Robinhood Chain (see the bridge
//                       page on nlyra.xyz for the live address)
//
//  Beware of copies: the only official NLYRA on Arbitrum is the one announced
//  on nlyra.xyz and in the Telegram group above.
// ============================================================================

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

/// @title NlyraOFT
/// @notice Mint/burn representation of NLYRA on Arbitrum One (LayerZero V2 OFT). Supply exists only while locked in the adapter.
/// @dev Only addition to the stock OFT: an outbound rate limit per destination eid (LayerZero RateLimiter).
///      A destination with no configured limit has capacity 0, so sends to it revert (fail closed).
contract NlyraOFT is OFT, RateLimiter {
    /// @param _lzEndpoint LayerZero EndpointV2 on this chain
    /// @param _owner      owner and LayerZero delegate (the treasury)
    constructor(address _lzEndpoint, address _owner) OFT("NLYRA", "NLYRA", _lzEndpoint, _owner) Ownable(_owner) {}

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
