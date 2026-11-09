# TrendRace

TrendRace is a daily player-vs-player (parimutuel) race on BNB Smart Chain. Each day five lanes race for 24 hours: BNB, BTC, ETH, CAKE and ALTS (SOL, XRP, LINK). Players stake BNB on the lane they think will rise most in USD. The contract computes the result itself from PancakeSwap V3 30-minute TWAP prices, so no one picks the winner.

- App: https://trendrace.xyz
- X: https://x.com/trendrace_xyz

## How it works

1. A new race opens every day at 13:00 UTC (20:00 UTC+7).
2. Start and end prices are PancakeSwap V3 TWAPs (30-minute window) read on-chain at fixed checkpoints.
3. The lane with the highest USD % change wins. Winners share the whole pot pro rata.
4. A 4% fee applies to winning payouts only. Losing stakes and refunds are fee-free.
5. If a checkpoint is missed past the grace period, the race is cancelled and everyone can claim a 100% refund.

Non-custodial: players claim payouts or refunds directly from the contract. Players can lose their stake. 18+ and only where permitted.

## Technology Stack

- Blockchain: BNB Smart Chain
- Smart contracts: Solidity 0.8.28
- Price source: PancakeSwap V3 pool oracles (TWAP)
- Development and tests: Foundry (unit, fuzz and fork tests)
- Frontend: static HTML/JS dApp with an injected EIP-1193 wallet

## Supported Networks

- BNB Smart Chain Mainnet (Chain ID: 56)
- BNB Smart Chain Testnet (Chain ID: 97)

## Contract Addresses

| Network | Contract | Address |
| --- | --- | --- |
| BNB Smart Chain Mainnet | TrendRace | [0xdc16B2882D18478406a71cfe7b284A627b8B0F58](https://bscscan.com/address/0xdc16B2882D18478406a71cfe7b284A627b8B0F58) |
| BNB Smart Chain Testnet | TrendRace | [0x6D7E19aD90694AD86c04123FD768b5bfD1e019F3](https://testnet.bscscan.com/address/0x6D7E19aD90694AD86c04123FD768b5bfD1e019F3) |

Mainnet source is verified on Sourcify (exact match).

## Build and test

```bash
cd contracts
forge install foundry-rs/forge-std
forge test
```

## License

MIT
