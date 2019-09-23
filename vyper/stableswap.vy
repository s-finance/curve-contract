from vyper.interfaces import ERC20

# This can (and needs to) be changed at compile time
N_COINS: constant(int128) = 3

coins: public(address[N_COINS])
balances: public(uint256[N_COINS])
A: public(int128)  # 2 x amplification coefficient
fee: public(int128)  # fee * 1e10
admin_fee: public(int128)  # admin_fee * 1e10
max_admin_fee: constant(int128) = 5 * 10 ** 9

owner: public(address)

admin_actions_delay: constant(uint256) = 7 * 86400
admin_actions_deadline: public(uint256)
transfer_ownership_deadline: public(uint256)
future_A: public(int128)
future_fee: public(int128)
future_admin_fee: public(int128)
future_owner: public(address)


@public
def __init__(_coins: address[N_COINS], _A: int128, _fee: int128):
    for i in range(N_COINS):
        assert _coins[i] != ZERO_ADDRESS
    self.coins = _coins
    self.A = _A
    self.fee = _fee
    self.admin_fee = 0
    self.owner = msg.sender


@public
@nonreentrant('lock')
def add_liquidity(i: int128, quantity_i: uint256,
                  max_quantity_other: uint256, deadline: timestamp):
    # XXX
    # Tokenizing the liquidity MUST be added
    # And it's not there yet
    # XXX TODO
    assert i < N_COINS, "Coin number out of range"
    assert block.timestamp <= deadline, "Transaction expired"
    d_bal: uint256[N_COINS]

    for j in range(N_COINS):
        if j == i:
            d_bal[j] = quantity_i
        else:
            if self.balances[i] > 0:
                d_bal[j] = quantity_i * self.balances[j] / self.balances[i]
            else:
                d_bal[j] = quantity_i
            if max_quantity_other > 0:
                assert d_bal[j] <= max_quantity_other
        assert ERC20(self.coins[j]).balanceOf(msg.sender) >= d_bal[j]
        assert ERC20(self.coins[j]).allowance(msg.sender, self) >= d_bal[j]

    ok: bool
    for j in range(N_COINS):
        self.balances[j] += d_bal[j]
        ok = ERC20(self.coins[j]).transferFrom(msg.sender, self, d_bal[j])
        assert ok


@private
@constant
def get_y(i: int128, j: int128, x: uint256) -> uint256:
    # === Calculate D ===
    Dprev: uint256 = 0
    S: uint256
    for _x in self.balances:
        S += _x
    assert S > 0
    D: uint256 = S
    Ann: uint256 = convert(self.A, uint256) * N_COINS
    for _i in range(255):
        D_P: uint256 = D
        for _x in self.balances:
            D_P = D_P * D / (_x * N_COINS)
        Dprev = D
        D = (Ann * S + D_P * N_COINS) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P)
        # Equality with the precision of 1
        if D > Dprev:
            if D - Dprev <= 1:
                break
        else:
            if Dprev - D <= 1:
                break
    # === D is now calculated ===

    # === Calculate y ===
    c: uint256 = D
    S_: uint256 = 0
    for _i in range(N_COINS):
        _x: uint256
        if _i == i:
            _x = x
        elif _i != j:
            _x = self.balances[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D / (Ann * N_COINS)
    b: uint256 = S_ + D / Ann  # - D
    y_prev: uint256 = 0
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                break
        else:
            if y_prev - y <= 1:
                break
    # === y is now calculated
    return y


@public
@constant
def get_dy(i: int128, j: int128, dx: uint256) -> uint256:
    x: uint256 = self.balances[i] + dx
    y: uint256 = self.get_y(i, j, x)
    return self.balances[j] - y


@public
@nonreentrant('lock')
def exchange(i: int128, j: int128, dx: uint256,
             min_dy: uint256, deadline: timestamp):
    assert block.timestamp <= deadline, "Transaction expired"
    assert i < N_COINS and j < N_COINS, "Coin number out of range"
    ok: bool

    x: uint256 = self.balances[i] + dx
    y: uint256 = self.get_y(i, j, x)
    dy: uint256 = self.balances[j] - y
    dy_fee: uint256 = dy * convert(self.fee, uint256) / (10 ** 10)
    dy_admin_fee: uint256 = dy_fee * convert(self.admin_fee, uint256) / (10 ** 10)
    self.balances[i] += dx
    self.balances[j] = y + (dy_fee - dy_admin_fee)

    ok = ERC20(self.coins[i]).transferFrom(msg.sender, self, dx)
    assert ok
    ok = ERC20(self.coins[j]).transfer(msg.sender, dy - dy_fee)
    assert ok