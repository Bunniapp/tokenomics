# Bunni tokenomics

Smart contracts used for Bunni tokenomics.

## Components

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
forge test
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
