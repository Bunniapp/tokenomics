#pragma version ^0.4.0
"""
@title Voting Escrow
@author Curve Finance
@license MIT
@notice Votes have a weight depending on time, so that users are
        committed to the future of (whatever they are voting for)
@dev Vote weight decays linearly over time. Lock time cannot be
     more than `MAXTIME` (1 year).
"""

# Voting escrow to have time-weighted votes
# Votes have a weight depending on time, so that users are committed
# to the future of (whatever they are voting for).
# The weight in this implementation is linear, and lock cannot be more than maxtime:
# w ^
# 1 +        /
#   |      /
#   |    /
#   |  /
#   |/
# 0 +--------+------> time
#       maxtime (1 year)

##
# SECTION IMPORTS
##

import LibMulticaller

# !SECTION IMPORTS


##
# SECTION INTERFACES
##

from ethereum.ercs import IERC20 as ERC20
from ethereum.ercs import IERC20Detailed

# Interface for checking whether address belongs to a whitelisted
# type of a smart wallet.
# When new types are added - the whole contract is changed
# The check() method is modifying to be able to use caching
# for individual wallet addresses
interface SmartWalletChecker:
    def check(addr: address) -> bool: nonpayable

implements: IERC20Detailed

# !SECTION INTERFACES


##
# SECTION STRUCTS
##

# We cannot really do block numbers per se b/c slope is per time, not per block
# and per block could be fairly bad b/c Ethereum changes blocktimes.
# What we can do is to extrapolate ***At functions
struct Point:
    bias: int128
    slope: int128  # - dweight // dt
    ts: uint256
    blk: uint256  # block

struct LockedBalance:
    amount: int128
    end: uint256

# !SECTION STRUCTS


##
# SECTION EVENTS
##

CREATE_LOCK_TYPE: constant(int128) = 1
INCREASE_LOCK_AMOUNT: constant(int128) = 2
INCREASE_UNLOCK_TIME: constant(int128) = 3
AIRDROP_LOCK_TYPE: constant(int128) = 4

event Deposit:
    provider: indexed(address)
    value: uint256
    locktime: indexed(uint256)
    type: int128
    ts: uint256

event Withdraw:
    provider: indexed(address)
    value: uint256
    ts: uint256

event Supply:
    prevSupply: uint256
    supply: uint256

event NewPendingAdmin:
    new_pending_admin: address

event NewAdmin:
    new_admin: address

event NewPendingSmartWalletChecker:
    new_pending_smart_wallet_checker: indexed(address)

event NewSmartWalletChecker:
    new_smart_wallet_checker: indexed(address)

event BurnUnlockFuse: pass

event ApproveAirdrop:
    locker: indexed(address)
    airdropper: indexed(address)

# !SECTION EVENTS


##
# SECTION CONSTANTS
##

WEEK: constant(uint256) = 7 * 86400  # all future times are rounded by week
MAXTIME: constant(uint256) = 365 * 86400  # 1 year
MULTIPLIER: constant(uint256) = 10 ** 18

# !SECTION CONSTANTS


##
# SECTION IMMUTABLES
##

TOKEN: immutable(address)
NAME: immutable(String[64])
SYMBOL: immutable(String[32])
DECIMALS: immutable(uint8)

# !SECTION IMMUTABLES


##
# SECTION STORAGE
##

pending_admin: public(address)
admin: public(address)

supply: public(uint256)
locked: public(HashMap[address, LockedBalance])

# Checker for whitelisted (smart contract) wallets which are allowed to deposit
# The goal is to prevent tokenizing the escrow
future_smart_wallet_checker: public(address)
smart_wallet_checker: public(address)

epoch: public(uint256)
user_point_history: public(HashMap[address, Point[1000000000]])  # user -> Point[user_epoch]
user_point_epoch: public(HashMap[address, uint256])
slope_changes: public(HashMap[uint256, int128])  # time -> signed slope change
point_history: public(Point[100000000000000000000000000000])  # epoch -> unsigned point

unlock_fuse: public(bool) # Can be permanently set to true to unlock all positions

# !SECTION STORAGE


##
# SECTION TRANSIENT STORAGE
##

# Lockers can allow another address to airdrop locked tokens to them and increase their lock time to the maximum.
# Transient storage is used so that such approvals only last for the duration of the transaction.
allow_airdrop: public(transient(HashMap[address, HashMap[address, bool]])) # locker -> airdropper -> allowed

# !SECTION TRANSIENT STORAGE


##
# SECTION CONSTRUCTOR
##

@deploy
def __init__(token_addr: address, _name: String[64], _symbol: String[32], _admin: address, _smart_wallet_checker: address):
    """
    @notice Contract constructor
    @param token_addr The token to escrow
    @param _name Token name
    @param _symbol Token symbol
    @param _admin The admin address
    """
    assert _admin != empty(address)

    TOKEN = token_addr
    self.admin = _admin
    self.point_history[0].blk = block.number
    self.point_history[0].ts = block.timestamp
    self.smart_wallet_checker = _smart_wallet_checker

    _decimals: uint8 = staticcall IERC20Detailed(token_addr).decimals()

    NAME = _name
    SYMBOL = _symbol
    DECIMALS = _decimals

# !SECTION CONSTRUCTOR


##
# SECTION PUBLIC GETTERS
##

@external
@view
def token() -> address:
    return TOKEN


@external
@view
def name() -> String[64]:
    return NAME


@external
@view
def symbol() -> String[32]:
    return SYMBOL


@external
@view
def decimals() -> uint8:
    return DECIMALS


@external
@view
def get_last_user_slope(addr: address) -> int128:
    """
    @notice Get the most recently recorded rate of voting power decrease for `addr`
    @param addr Address of the user wallet
    @return Value of the slope
    """
    uepoch: uint256 = self.user_point_epoch[addr]
    return self.user_point_history[addr][uepoch].slope


@external
@view
def user_point_history__ts(_addr: address, _idx: uint256) -> uint256:
    """
    @notice Get the timestamp for checkpoint `_idx` for `_addr`
    @param _addr User wallet address
    @param _idx User epoch number
    @return Epoch time of the checkpoint
    """
    return self.user_point_history[_addr][_idx].ts


@external
@view
def locked__end(_addr: address) -> uint256:
    """
    @notice Get timestamp when `_addr`'s lock finishes
    @param _addr User wallet
    @return Epoch time of the lock end
    """
    return self.locked[_addr].end


@external
@view
def balanceOf(addr: address, _t: uint256 = block.timestamp) -> uint256:
    """
    @notice Get the current voting power for `addr`
    @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    @param addr User wallet address
    @param _t Epoch time to return voting power at
    @return User voting power
    """
    _epoch: uint256 = 0
    if _t == block.timestamp:
        # No need to do binary search, will always live in current epoch
        _epoch = self.user_point_epoch[addr]
    else:
        _epoch = self.find_timestamp_user_epoch(addr, _t, self.user_point_epoch[addr])

    if _epoch == 0:
        return 0
    else:
        last_point: Point = self.user_point_history[addr][_epoch]
        last_point.bias -= last_point.slope * convert(_t - last_point.ts, int128)
        if last_point.bias < 0:
            last_point.bias = 0
        return convert(last_point.bias, uint256)


@external
@view
def balanceOfAt(addr: address, _block: uint256) -> uint256:
    """
    @notice Measure voting power of `addr` at block height `_block`
    @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    @param addr User's wallet address
    @param _block Block to calculate the voting power at
    @return Voting power
    """
    # Copying and pasting totalSupply code because Vyper cannot pass by
    # reference yet
    assert _block <= block.number

    _user_epoch: uint256 = self.find_block_user_epoch(addr, _block, self.user_point_epoch[addr])
    upoint: Point = self.user_point_history[addr][_user_epoch]

    max_epoch: uint256 = self.epoch
    _epoch: uint256 = self.find_block_epoch(_block, max_epoch)
    point_0: Point = self.point_history[_epoch]
    d_block: uint256 = 0
    d_t: uint256 = 0
    if _epoch < max_epoch:
        point_1: Point = self.point_history[_epoch + 1]
        d_block = point_1.blk - point_0.blk
        d_t = point_1.ts - point_0.ts
    else:
        d_block = block.number - point_0.blk
        d_t = block.timestamp - point_0.ts
    block_time: uint256 = point_0.ts
    if d_block != 0:
        block_time += d_t * (_block - point_0.blk) // d_block

    upoint.bias -= upoint.slope * convert(block_time - upoint.ts, int128)
    if upoint.bias >= 0:
        return convert(upoint.bias, uint256)
    else:
        return 0


@external
@view
def totalSupply(t: uint256 = block.timestamp) -> uint256:
    """
    @notice Calculate total voting power
    @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    @return Total voting power
    """
    _epoch: uint256 = 0
    if t == block.timestamp:
        # No need to do binary search, will always live in current epoch
        _epoch = self.epoch
    else:
        _epoch = self.find_timestamp_epoch(t, self.epoch)

    if _epoch == 0:
        return 0
    else:
        last_point: Point = self.point_history[_epoch]
        return self.supply_at(last_point, t)


@external
@view
def totalSupplyAt(_block: uint256) -> uint256:
    """
    @notice Calculate total voting power at some point in the past
    @param _block Block to calculate the total voting power at
    @return Total voting power at `_block`
    """
    assert _block <= block.number
    _epoch: uint256 = self.epoch
    target_epoch: uint256 = self.find_block_epoch(_block, _epoch)

    point: Point = self.point_history[target_epoch]
    dt: uint256 = 0
    if target_epoch < _epoch:
        point_next: Point = self.point_history[target_epoch + 1]
        if point.blk != point_next.blk:
            dt = (_block - point.blk) * (point_next.ts - point.ts) // (point_next.blk - point.blk)
    else:
        if point.blk != block.number:
            dt = (_block - point.blk) * (block.timestamp - point.ts) // (block.number - point.blk)
    # Now dt contains info on how far are we beyond point

    return self.supply_at(point, point.ts + dt)

# !SECTION PUBLIC GETTERS


##
# SECTION LOCKER ACTIONS
#

@external
def checkpoint():
    """
    @notice Record global data to checkpoint
    """
    self._checkpoint(empty(address), empty(LockedBalance), empty(LockedBalance))


@external
@nonreentrant
def create_lock(_value: uint256, _unlock_time: uint256):
    """
    @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
    @param _value Amount to deposit
    @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
    """
    msg_sender: address = LibMulticaller.sender_or_signer()
    self.assert_not_contract(msg_sender)
    unlock_time: uint256 = (_unlock_time // WEEK) * WEEK  # Locktime is rounded down to weeks
    _locked: LockedBalance = self.locked[msg_sender]

    assert _value > 0  # dev: need non-zero value
    assert _locked.amount == 0, "Withdraw old tokens first"
    assert unlock_time > block.timestamp, "Can only lock until time in the future"
    assert unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 1 year max"

    self._deposit_for(msg_sender, _value, unlock_time, _locked, CREATE_LOCK_TYPE)


@external
@nonreentrant
def increase_amount(_value: uint256):
    """
    @notice Deposit `_value` additional tokens for `msg.sender`
            without modifying the unlock time
    @param _value Amount of tokens to deposit and add to the lock
    """
    msg_sender: address = LibMulticaller.sender_or_signer()
    self.assert_not_contract(msg_sender)
    _locked: LockedBalance = self.locked[msg_sender]

    assert _value > 0  # dev: need non-zero value
    assert _locked.amount > 0, "No existing lock found"
    assert _locked.end > block.timestamp, "Cannot add to expired lock. Withdraw"

    self._deposit_for(msg_sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT)


@external
@nonreentrant
def increase_unlock_time(_unlock_time: uint256):
    """
    @notice Extend the unlock time for `msg.sender` to `_unlock_time`
    @param _unlock_time New epoch time for unlocking
    """
    msg_sender: address = LibMulticaller.sender_or_signer()
    self.assert_not_contract(msg_sender)
    _locked: LockedBalance = self.locked[msg_sender]
    unlock_time: uint256 = (_unlock_time // WEEK) * WEEK  # Locktime is rounded down to weeks

    assert _locked.end > block.timestamp, "Lock expired"
    assert _locked.amount > 0, "Nothing is locked"
    assert unlock_time > _locked.end, "Can only increase lock duration"
    assert unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 1 year max"

    self._deposit_for(msg_sender, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME)


@external
@nonreentrant
def withdraw():
    """
    @notice Withdraw all tokens for `msg.sender`
    @dev Only possible if the lock has expired
    """
    msg_sender: address = LibMulticaller.sender_or_signer()
    _locked: LockedBalance = self.locked[msg_sender]
    assert (block.timestamp >= _locked.end) or self.unlock_fuse, "The lock didn't expire or the unlock fuse has not been burnt"
    value: uint256 = convert(_locked.amount, uint256)

    old_locked: LockedBalance = _locked
    _locked.end = 0
    _locked.amount = 0
    self.locked[msg_sender] = _locked
    supply_before: uint256 = self.supply
    self.supply = supply_before - value

    # old_locked can have either expired <= timestamp or zero end
    # _locked has only 0 end
    # Both can have >= 0 amount
    self._checkpoint(msg_sender, old_locked, _locked)

    assert extcall ERC20(TOKEN).transfer(msg_sender, value)

    log Withdraw(msg_sender, value, block.timestamp)
    log Supply(supply_before, supply_before - value)


@external
def approve_airdrop(airdropper: address):
    """
    @notice Approve an address to airdrop locked tokens to the caller for the duration of the transaction.
    @param airdropper The address that will be allowed to airdrop tokens.
    """
    msg_sender: address = LibMulticaller.sender_or_signer()
    self.allow_airdrop[msg_sender][airdropper] = True
    log ApproveAirdrop(msg_sender, airdropper)

# !SECTION LOCKER ACTIONS


##
# SECTION AIRDROPPER ACTIONS
##

@external
@nonreentrant
def airdrop(_to: address, _value: uint256, _unlock_time: uint256):
    msg_sender: address = LibMulticaller.sender_or_signer()
    self.assert_not_contract(_to)
    unlock_time: uint256 = (_unlock_time // WEEK) * WEEK  # Locktime is rounded down to weeks
    _locked: LockedBalance = self.locked[_to]

    assert _value > 0  # dev: need non-zero value
    assert unlock_time > block.timestamp, "Can only lock until time in the future"
    assert unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 1 year max"
    assert self.allow_airdrop[_to][msg_sender], "Airdrop not allowed"

    # update supply
    supply_before: uint256 = self.supply
    self.supply = supply_before + _value

    # update locked balance
    old_locked: LockedBalance = _locked
    # airdropper can only extend the lock time, not decrease it
    _locked.amount += convert(_value, int128)
    _locked.end = max(unlock_time, _locked.end)
    self.locked[_to] = _locked

    # checkpoint the user's locked balance
    self._checkpoint(_to, old_locked, _locked)

    # transfer tokens from the airdropper
    assert extcall ERC20(TOKEN).transferFrom(msg_sender, self, _value)

    log Deposit(_to, _value, _locked.end, AIRDROP_LOCK_TYPE, block.timestamp)
    log Supply(supply_before, supply_before + _value)


# !SECTION AIRDROPPER ACTIONS


##
# SECTION ADMIN ACTIONS
##

@external
def commit_smart_wallet_checker(addr: address):
    """
    @notice Set an external contract to check for approved smart contract wallets
    @param addr Address of Smart contract checker
    """
    assert msg.sender == self.admin
    self.future_smart_wallet_checker = addr

    log NewPendingSmartWalletChecker(addr)


@external
def apply_smart_wallet_checker():
    """
    @notice Apply setting external contract to check approved smart contract wallets
    """
    assert msg.sender == self.admin
    new_checker: address = self.future_smart_wallet_checker
    self.smart_wallet_checker = new_checker

    log NewSmartWalletChecker(new_checker)


@external
def burn_unlock_fuse():
    """
    @notice Burn unlock fuse permanently and allow all users to withdraw
    """
    assert msg.sender == self.admin
    self.unlock_fuse = True

    log BurnUnlockFuse()


@external
def change_pending_admin(new_pending_admin: address):
    """
    @notice Change pending_admin to `new_pending_admin`
    @param new_pending_admin The new pending_admin address
    """
    assert msg.sender == self.admin

    self.pending_admin = new_pending_admin

    log NewPendingAdmin(new_pending_admin)


@external
def claim_admin():
    """
    @notice Called by pending_admin to set admin to pending_admin
    """
    assert msg.sender == self.pending_admin

    self.admin = msg.sender
    self.pending_admin = empty(address)

    log NewAdmin(msg.sender)

# !SECTION ADMIN ACTIONS


##
# SECTION INTERNAL UTILITIES
##

@internal
@view
def find_block_epoch(_block: uint256, max_epoch: uint256) -> uint256:
    """
    @notice Binary search to find epoch containing block number
    @param _block Block to find
    @param max_epoch Don't go beyond this epoch
    @return Epoch which contains _block
    """
    # Binary search
    _min: uint256 = 0
    _max: uint256 = max_epoch
    for i: uint256 in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 1) // 2
        if self.point_history[_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@internal
@view
def find_timestamp_epoch(_timestamp: uint256, max_epoch: uint256) -> uint256:
    """
    @notice Binary search to find epoch for timestamp
    @param _timestamp timestamp to find
    @param max_epoch Don't go beyond this epoch
    @return Epoch which contains _timestamp
    """
    # Binary search
    _min: uint256 = 0
    _max: uint256 = max_epoch
    for i: uint256 in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 1) // 2
        if self.point_history[_mid].ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@internal
@view
def find_block_user_epoch(_addr: address, _block: uint256, max_epoch: uint256) -> uint256:
    """
    @notice Binary search to find epoch for block number
    @param _addr User for which to find user epoch for
    @param _block Block to find
    @param max_epoch Don't go beyond this epoch
    @return Epoch which contains _block
    """
    # Binary search
    _min: uint256 = 0
    _max: uint256 = max_epoch
    for i: uint256 in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 1) // 2
        if self.user_point_history[_addr][_mid].blk <= _block:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@internal
@view
def find_timestamp_user_epoch(_addr: address, _timestamp: uint256, max_epoch: uint256) -> uint256:
    """
    @notice Binary search to find user epoch for timestamp
    @param _addr User for which to find user epoch for
    @param _timestamp timestamp to find
    @param max_epoch Don't go beyond this epoch
    @return Epoch which contains _timestamp
    """
    # Binary search
    _min: uint256 = 0
    _max: uint256 = max_epoch
    for i: uint256 in range(128):  # Will be always enough for 128-bit numbers
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 1) // 2
        if self.user_point_history[_addr][_mid].ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min


@internal
@view
def supply_at(point: Point, t: uint256) -> uint256:
    """
    @notice Calculate total voting power at some point in the past
    @param point The point (bias/slope) to start search from
    @param t Time to calculate the total voting power at
    @return Total voting power at that time
    """
    last_point: Point = point
    t_i: uint256 = (last_point.ts // WEEK) * WEEK
    for i: uint256 in range(255):
        t_i += WEEK
        d_slope: int128 = 0
        if t_i > t:
            t_i = t
        else:
            d_slope = self.slope_changes[t_i]
        last_point.bias -= last_point.slope * convert(t_i - last_point.ts, int128)
        if t_i == t:
            break
        last_point.slope += d_slope
        last_point.ts = t_i

    if last_point.bias < 0:
        last_point.bias = 0
    return convert(last_point.bias, uint256)


@internal
def assert_not_contract(addr: address):
    """
    @notice Check if the call is from a whitelisted smart contract, revert if not
    @param addr Address to be checked
    """
    if addr != tx.origin:
        checker: address = self.smart_wallet_checker
        if checker != empty(address):
            if extcall SmartWalletChecker(checker).check(addr):
                return
        raise "Smart contract depositors not allowed"


@internal
def _checkpoint(addr: address, old_locked: LockedBalance, new_locked: LockedBalance):
    """
    @notice Record global and per-user data to checkpoint
    @param addr User's wallet address. No user checkpoint if 0x0
    @param old_locked Pevious locked amount / end lock time for the user
    @param new_locked New locked amount / end lock time for the user
    """
    u_old: Point = empty(Point)
    u_new: Point = empty(Point)
    old_dslope: int128 = 0
    new_dslope: int128 = 0
    _epoch: uint256 = self.epoch

    if addr != empty(address):
        # Calculate slopes and biases
        # Kept at zero when they have to
        if old_locked.end > block.timestamp and old_locked.amount > 0:
            u_old.slope = old_locked.amount // convert(MAXTIME, int128)
            u_old.bias = u_old.slope * convert(old_locked.end - block.timestamp, int128)
        if new_locked.end > block.timestamp and new_locked.amount > 0:
            u_new.slope = new_locked.amount // convert(MAXTIME, int128)
            u_new.bias = u_new.slope * convert(new_locked.end - block.timestamp, int128)

        # Read values of scheduled changes in the slope
        # old_locked.end can be in the past and in the future
        # new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
        old_dslope = self.slope_changes[old_locked.end]
        if new_locked.end != 0:
            if new_locked.end == old_locked.end:
                new_dslope = old_dslope
            else:
                new_dslope = self.slope_changes[new_locked.end]

    last_point: Point = Point(bias=0, slope=0, ts=block.timestamp, blk=block.number)
    if _epoch > 0:
        last_point = self.point_history[_epoch]
    last_checkpoint: uint256 = last_point.ts
    # initial_last_point is used for extrapolation to calculate block number
    # (approximately, for *At methods) and save them
    # as we cannot figure that out exactly from inside the contract
    initial_last_point: Point = last_point
    block_slope: uint256 = 0  # dblock/dt
    if block.timestamp > last_point.ts:
        block_slope = MULTIPLIER * (block.number - last_point.blk) // (block.timestamp - last_point.ts)
    # If last point is already recorded in this block, slope=0
    # But that's ok b/c we know the block in such case

    # Go over weeks to fill history and calculate what the current point is
    t_i: uint256 = (last_checkpoint // WEEK) * WEEK
    for i: uint256 in range(255):
        # Hopefully it won't happen that this won't get used in 5 years!
        # If it does, users will be able to withdraw but vote weight will be broken
        t_i += WEEK
        d_slope: int128 = 0
        if t_i > block.timestamp:
            t_i = block.timestamp
        else:
            d_slope = self.slope_changes[t_i]
        last_point.bias -= last_point.slope * convert(t_i - last_checkpoint, int128)
        last_point.slope += d_slope
        if last_point.bias < 0:  # This can happen
            last_point.bias = 0
        if last_point.slope < 0:  # This cannot happen - just in case
            last_point.slope = 0
        last_checkpoint = t_i
        last_point.ts = t_i
        last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) // MULTIPLIER
        _epoch += 1
        if t_i == block.timestamp:
            last_point.blk = block.number
            break
        else:
            self.point_history[_epoch] = last_point

    self.epoch = _epoch
    # Now point_history is filled until t=now

    if addr != empty(address):
        # If last point was in this block, the slope change has been applied already
        # But in such case we have 0 slope(s)
        last_point.slope += (u_new.slope - u_old.slope)
        last_point.bias += (u_new.bias - u_old.bias)
        if last_point.slope < 0:
            last_point.slope = 0
        if last_point.bias < 0:
            last_point.bias = 0

    # Record the changed point into history
    self.point_history[_epoch] = last_point

    if addr != empty(address):
        # Schedule the slope changes (slope is going down)
        # We subtract new_user_slope from [new_locked.end]
        # and add old_user_slope to [old_locked.end]
        if old_locked.end > block.timestamp:
            # old_dslope was <something> - u_old.slope, so we cancel that
            old_dslope += u_old.slope
            if new_locked.end == old_locked.end:
                old_dslope -= u_new.slope  # It was a new deposit, not extension
            self.slope_changes[old_locked.end] = old_dslope

        if new_locked.end > block.timestamp:
            if new_locked.end > old_locked.end:
                new_dslope -= u_new.slope  # old slope disappeared at this point
                self.slope_changes[new_locked.end] = new_dslope
            # else: we recorded it already in old_dslope

        # Now handle user history
        user_epoch: uint256 = self.user_point_epoch[addr] + 1

        self.user_point_epoch[addr] = user_epoch
        u_new.ts = block.timestamp
        u_new.blk = block.number
        self.user_point_history[addr][user_epoch] = u_new


@internal
def _deposit_for(_addr: address, _value: uint256, unlock_time: uint256, locked_balance: LockedBalance, type: int128):
    """
    @notice Deposit and lock tokens for a user
    @param _addr User's wallet address
    @param _value Amount to deposit
    @param unlock_time New time when to unlock the tokens, or 0 if unchanged
    @param locked_balance Previous locked amount / timestamp
    """
    _locked: LockedBalance = locked_balance
    supply_before: uint256 = self.supply

    self.supply = supply_before + _value
    old_locked: LockedBalance = _locked
    # Adding to existing lock, or if a lock is expired - creating a new one
    _locked.amount += convert(_value, int128)
    if unlock_time != 0:
        _locked.end = unlock_time
    self.locked[_addr] = _locked

    # Possibilities:
    # Both old_locked.end could be current or expired (>/< block.timestamp)
    # value == 0 (extend lock) or value > 0 (add to lock or extend lock)
    # _locked.end > block.timestamp (always)
    self._checkpoint(_addr, old_locked, _locked)

    if _value != 0:
        assert extcall ERC20(TOKEN).transferFrom(_addr, self, _value)

    log Deposit(_addr, _value, _locked.end, type, block.timestamp)
    log Supply(supply_before, supply_before + _value)

# !SECTION INTERNAL UTILITIES