# Moth contracts

The smart contracts behind [Moth](https://runmoth.si) on Robinhood Chain (chain id 4663). They take payments for credit, split the $MOTH swap tax and move funds between USDG, ETH and $MOTH.

The files here are the exact sources of the contracts that are live. The table below lists each one, and [Check the live code](#check-the-live-code) shows how to confirm it yourself.

## Live contracts

| Contract | Address | Source |
|---|---|---|
| Tax splitter | `0x86234b07F0f08d7Ab364BA141ca59bcf3938365C` | `vault-and-splitter/src/MothTaxSplitter.sol` |
| Vault | `0xC35254c7Fd114a553E8f83336e569F7a11B4D39a` | `vault-and-splitter/src/MothVault.sol` |
| ETH to USDG route | `0x095f4E391912153B73FeF7956F0eAb353b0612C8` | `vault-and-splitter/src/swappers/UsdgSwapper.sol` |
| USDG to ETH route | `0x7aef33F3d0d9c6F07e1e845f63454aea4BE3799e` | `vault-and-splitter/src/swappers/UsdgSeller.sol` |
| $MOTH to ETH route | `0x0f751404A519513e1b9183fF6A7f59f51356132B` | `vault-and-splitter/src/swappers/PonsTokenSeller.sol` |
| ETH to $MOTH route | `0x522F4434fD7D6F7ccEEbdC528Ec4fCDa6151B6e5` | `vault-and-splitter/src/swappers/PonsTokenBuyer.sol` |
| Deposit factory | `0xb37AcC1E91E3b94b77c2284151069D680DDa083f` | `deposits/src/DepositFactory.sol` |
| Deposit forwarder (implementation) | `0x950a24b4911e5D46b4d3eA30E09100Eb75991aE1` | `deposits/src/DepositForwarder.sol` |

The $MOTH token is `0xB15Cd4C4E42Cdb25fc939815711EA7875F4AA844`. It was created on Pons, so its code is Pons's and is not in this repository. This repository is not an offer of $MOTH or any other token.

## What each part does

**Deposits.** Each Moth account has its own deposit address on Robinhood Chain. It is a minimal forwarder (an ERC-1167 clone) whose address the API works out before anything is deployed. Anyone can call `sweep` on the factory to deploy missing forwarders and send what they hold to the vault, because funds can only go to the vault. The forwarder has no owner and no upgrade path.

**Vault.** The vault holds what people pay for credit. Credit itself lives in Moth's ledger, not in the contract. A keeper wallet runs the vault's five steps on a schedule, and each step checks a minimum output the keeper takes from a fresh quote.

- `processToken` can burn a set share of the $MOTH held by sending it to the dead address. That share is 0 today. It sells the rest for ETH and swaps what the gas reserve doesn't need to USDG.
- `processUsdg` can spend a set share of new USDG on buying $MOTH and burning it. That share is 0 today too.
- `paySupplier` sends USDG to the wallet that pays for inference, within a daily cap.
- `refuel` sells a capped amount of USDG for ETH when the vault's gas reserve is low.
- `fuelKeeper` tops up the keeper's gas, within a daily cap. Anyone can call it, since the ETH can only go to the keeper.

The keeper cannot withdraw, change a setting or choose where funds go. The owner can pause every step, but withdrawals still work while paused.

**Tax splitter.** Pons charges a creator tax on every $MOTH buy and sell and pays it to the splitter in ETH. One keeper call, `distribute`, collects it and splits it three ways by shares the owner sets.

| Share | Today (basis points) | Goes to |
|---|---|---|
| Burn | 833 | $MOTH bought on Pons and sent to `0x000000000000000000000000000000000000dEaD` |
| Holder credit | 2,500 | swapped to USDG and paid to the vault, where it becomes credit for holders |
| Development | 6,667 | ETH to the development wallet |

Every change to the split, the wallets, the routes or the keeper emits an event. There is no upgrade path, and ETH and $MOTH leave the splitter only through `distribute`.

**Swap routes.** Each route takes its input, measures what reaches the recipient, checks it against the caller's minimum and returns unused input. The two $MOTH routes trade on Pons against native ETH, using the bonding curve before graduation and the Uniswap v4 pool after it. The two USDG routes trade in the native ETH and USDG Uniswap v4 pool (fee 500, tick spacing 10, no hook).

## Build and test

You need [Foundry](https://getfoundry.sh) and solc 0.8.35. The tests use no libraries, so nothing else is downloaded.

```bash
cd vault-and-splitter
forge build
forge test --no-match-path 'test/fork/*'
```

```bash
cd deposits
forge test
```

The fork tests in `vault-and-splitter/test/fork/` run against the real Pons, Uniswap and USDG contracts on a fork of Robinhood Chain.

```bash
cd vault-and-splitter
RPC=https://rpc.mainnet.chain.robinhood.com
FORK_URL=$RPC forge test --match-path 'test/fork/*' --fork-url $RPC --fork-block-number $(( $(cast block-number --rpc-url $RPC) - 100 ))
```

## Check the live code

Solidity puts a hash of a contract's sources and settings at the end of its bytecode. If the hash in your build equals the one on chain, the sources match exactly, comments included. This checks the vault.

```bash
cd vault-and-splitter
forge build
cast code 0xC35254c7Fd114a553E8f83336e569F7a11B4D39a --rpc-url https://rpc.mainnet.chain.robinhood.com | tail -c 120
jq -r .deployedBytecode.object out/MothVault.sol/MothVault.json | tail -c 120
```

The two lines should end the same. Use the same steps for any contract in the table.

## Audit

These contracts have not had an independent audit. They are tested with unit tests and with fork tests against the live chain. Read the code before you rely on it.

## Security

Found a problem? Email dev@runmoth.si. Please don't open a public issue for a security bug.

## License

MIT. See [LICENSE](LICENSE).
