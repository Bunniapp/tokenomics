// SPDX-License-Identifier: AGPL-3.0

pragma solidity >=0.7.0 <0.9.0;

interface IVotingEscrow {
    function token() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function get_last_user_slope(address addr) external view returns (int128);
    function user_point_history__ts(address _addr, uint256 _idx) external view returns (uint256);
    function locked__end(address _addr) external view returns (uint256);
    function balanceOf(address addr, uint256 _t) external view returns (uint256);
    function balanceOfAt(address addr, uint256 _block) external view returns (uint256);
    function totalSupply(uint256 t) external view returns (uint256);
    function totalSupplyAt(uint256 _block) external view returns (uint256);
    function checkpoint() external;
    function create_lock(uint256 _value, uint256 _unlock_time) external;
    function increase_amount(uint256 _value) external;
    function increase_unlock_time(uint256 _unlock_time) external;
    function withdraw() external;
    function approve_airdrop(address airdropper) external;
    function airdrop(address _to, uint256 _value, uint256 _unlock_time) external;
    function commit_smart_wallet_checker(address addr) external;
    function apply_smart_wallet_checker() external;
    function change_pending_admin(address new_pending_admin) external;
    function claim_admin() external;
    function pending_admin() external view returns (address);
    function admin() external view returns (address);
    function supply() external view returns (uint256);
    function locked(address arg0) external view returns (LockedBalance memory);
    function future_smart_wallet_checker() external view returns (address);
    function smart_wallet_checker() external view returns (address);
    function epoch() external view returns (uint256);
    function user_point_history(address arg0, uint256 arg1) external view returns (Point memory);
    function user_point_epoch(address arg0) external view returns (uint256);
    function slope_changes(uint256 arg0) external view returns (int128);
    function point_history(uint256 arg0) external view returns (Point memory);
    function allow_airdrop(address arg0, address arg1) external view returns (bool);
    function unlock_fuse() external view returns (bool);
    function burn_unlock_fuse() external;

    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 eventType, uint256 ts);

    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    event Supply(uint256 prevSupply, uint256 supply);

    event NewPendingAdmin(address new_pending_admin);

    event NewAdmin(address new_admin);

    event NewPendingSmartWalletChecker(address new_pending_smart_wallet_checker);

    event NewSmartWalletChecker(address new_smart_wallet_checker);

    event BurnUnlockFuse();

    event ApproveAirdrop(address indexed locker, address indexed airdropper);
}

struct LockedBalance {
    int128 amount;
    uint256 end;
}

struct Point {
    int128 bias;
    int128 slope;
    uint256 ts;
    uint256 blk;
}
