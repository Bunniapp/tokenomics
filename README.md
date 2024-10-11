# Bunni tokenomics

Smart contracts used for Bunni tokenomics.

## Components

Note: The vast majority of the external functions of the following contracts support batch operations via [Multicaller](https://github.com/Vectorized/multicaller).

### MasterBunni

MasterBunni is a singleton contract for incentivizing Bunni v2 liquidity providers. It has two types of staking pools:

- **Rush Pools**: Single-use staking pools with:
  - deposit cap
  - refundable incentives
  - any number of incentive reward tokens
  - fixed reward-per-token-per-second throughout the program
- **Recur Pools**: Traditional staking pools:
  - no deposit cap
  - non-refundable incentives
  - single incentive reward token
  - variable reward-per-token-per-second based on the number of tokens staked

Additionally, MasterBunni has a few other features:

- Permissionless pool creation
- Permissionless incentive adding
- Staking the same tokens in any number of pools simultaneously

### BUNNI

BUNNI is the governance token of Bunni. It is a crosschain ERC20 token following the [XERC20](https://www.xerc20.com/) standard. BUNNI has a total supply of 1 billion tokens.

### OptionsToken

OptionsToken is the token that represents the right to purchase the underlying token (in our case, BUNNI) at an oracle-specified rate. The option does not expire, and the holder can exercise the option at any time. `BunniHookOracle` is used to query the TWAP value from a Bunni pool and compute the strike price.

### VotingEscrow

VotingEscrow is a contract that allows users to lock their BUNNI tokens for a period of time (up to 1 year) and receive voting power. The voting power is proportional to the amount of BUNNI tokens locked and the time the tokens are locked for. The voting power decays linearly over time.

VotingEscrow was forked from Curve's VotingEscrow contract. It was modified in the following ways:

- Use Vyper 0.4.0, which is the latest version at the time of development.
- Use [Multicaller](https://github.com/Vectorized/multicaller) to support batch operations.
- Support airdropping vote locked tokens. A user needs to call `approve_airdrop()` prior to the airdrop (in the same transaction due to the usage of transient storage) to signal their intention to receive the airdropped tokens.
- `deposit_for()` was removed since there's no use case for it.

### VeAirdrop

VeAirdrop is a contract that allows users to claim vote escrowed BUNNI tokens via a Merkle tree proof. It has a start and end time, and can only be claimed during that time. The veBUNNI position is max locked for 1 year starting from the time of claiming.

### TokenMigrator

TokenMigrator is a simple contract that allows users to migrate their old tokens (LIT) to new tokens (BUNNI) at a specified rate. The new tokens need to be transferred to the migrator contract to enable the migration. New tokens cannot be converted back into old tokens, and the migrated old tokens are locked in the migrator contract forever. The migration is perpetually active, but the contract owner can prevent further migration by calling `withdrawNewToken()` to withdraw the new tokens.

## Installation

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install bunniapp/bunni-tokenomics
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
forge install
```

### Compilation

```
forge build
```

### Testing

```
forge test -f sepolia
```

### Contract deployment

Please create a `.env` file before deployment. An example can be found in `.env.example`.

#### Dryrun

```
forge script script/Deploy.s.sol -f [network]
```

### Live

```
forge script script/Deploy.s.sol -f [network] --verify --broadcast
```
