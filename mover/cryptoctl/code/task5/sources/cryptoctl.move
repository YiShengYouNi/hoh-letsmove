/*
/// Module: task5
*/
module cryptoctl::swap;
use std::u64::sqrt;
use std::u64::min as u64Min;
use sui::coin;
use sui::coin::{Coin};
use sui::balance;
use sui::balance::{Supply, Balance};

/// For when supplied Coin is zero.
const EZeroAmount: u64 = 0;

/// For when someone tries to swap in an empty pool.
const EReservesEmpty: u64 = 2;

/// For when someone attempts to add more liquidity than u128 Math allows.
const EPoolFull: u64 = 4;

/// The integer scaling setting for fees calculation.
const FEE_SCALING: u128 = 10000;

/// The fee percent that will be taken from the swap.
/// Set to 0.3%.
const FEE_PERCENT: u128 = 30;

/// The max value that can be held in one of the Balances of
/// a Pool. U64 MAX / FEE_SCALING
const MAX_POOL_VALUE: u64 = {
    18446744073709551615 / 10000
};

/// The Pool token that will be used to mark the pool share
/// of a liquidity provider.
/// The first type parameter stands for the witness type of a pool.
/// The seconds and thirds is for the coin held in the pool.
public struct LSP<phantom TA, phantom TB> has drop {}


public struct Pool<phantom TA, phantom TB> has key {
    id: UID,
    token_a: Balance<TA>,
    token_b: Balance<TB>,
    lsp_supply: Supply<LSP<TA, TB>>,
    fee_percent: u64
}


/// Module initializer is empty - to publish a new Pool one has
/// to create a type which will mark LSPs.
fun init(_: &mut TxContext) {

}

entry fun create_pool<TA, TB> (
    token_a: Coin<TA>,
    token_b: Coin<TB>,
    ctx: &mut TxContext
) {

    let fee_percent = (FEE_PERCENT as u64);

    let token_a_amt = token_a.value();
    let token_b_amt = token_b.value();

    assert!(token_a_amt > 0 && token_b_amt > 0, EZeroAmount);
    assert!(token_a_amt < MAX_POOL_VALUE && token_b_amt < MAX_POOL_VALUE, EPoolFull);

    let share = sqrt(token_a_amt) * sqrt(token_b_amt);
    let mut lsp_supply = balance::create_supply(LSP<TA, TB> {});

    //let lsp = balance::increase_supply(&mut lsp_supply, share);
    let lsp = lsp_supply.increase_supply(share);

    transfer::share_object(Pool {
        id: object::new(ctx),
        token_a: coin::into_balance(token_a),
        token_b: coin::into_balance(token_b),
        lsp_supply,
        fee_percent,
    });

    transfer::public_transfer(
        coin::from_balance(lsp, ctx),
        tx_context::sender(ctx)
    );
}


entry fun add_liquidity<TA, TB> (
    pool: &mut Pool<TA, TB>,
    token_a: Coin<TA>,
    token_b: Coin<TB>,
    ctx: &mut TxContext
) {
    assert!(token_a.value() > 0 && token_b.value() > 0, EZeroAmount);

    let (token_a_amt, token_b_amt, lsp_supply) = get_amounts(pool);
    assert!(token_a_amt > 0 && token_b_amt > 0, EReservesEmpty);

    let token_a_balance = coin::into_balance(token_a);
    let token_b_balance = coin::into_balance(token_b);

    let token_a_added = token_a_balance.value();
    let token_b_added = token_b_balance.value();

    // XXX - 可以对新增的流动性进行计算，查看比值是否和原来的比值一致
    // assert!(token_a_added * token_b_amt == token_b_added * token_a_amt, EWrongFee);
    // assert!(math::abs_diff(token_a_added * token_b_amt, token_b_added * token_a_amt) < 100, EWrongFee);

    let share_minted = u64Min(
        (token_a_added * lsp_supply) / token_a_amt,
        (token_b_added * lsp_supply) / token_b_amt
    );

    let token_a_amt = pool.token_a.join(token_a_balance);
    let token_b_amt = pool.token_b.join(token_b_balance);

    assert!(token_a_amt < MAX_POOL_VALUE && token_b_amt < MAX_POOL_VALUE, EPoolFull);

    let balance = pool.lsp_supply.increase_supply(share_minted);

    transfer::public_transfer(
        coin::from_balance(balance, ctx),
        tx_context::sender(ctx)
    )
}


entry fun remove_liquidity<TA, TB> (
    pool: &mut Pool<TA, TB>,
    lsp: Coin<LSP<TA, TB>>,
    ctx: &mut TxContext
) {
    let (token_a, token_b) = remove_liquidity_inner(pool, lsp, ctx);
    let sender = tx_context::sender(ctx);

    transfer::public_transfer(token_a, sender);
    transfer::public_transfer(token_b, sender);
}

fun remove_liquidity_inner<TA, TB> (
    pool: &mut Pool<TA, TB>,
    lsp: Coin<LSP<TA, TB>>,
    ctx: &mut TxContext
): (Coin<TA>, Coin<TB>) {
    let lsp_amount = lsp.value();
    assert!(lsp_amount > 0, EZeroAmount);

    let (token_a_amt, token_b_amt, total_supply) = get_amounts(pool);

    let token_a = (token_a_amt * lsp_amount) / total_supply;
    let token_b = (token_b_amt * lsp_amount) / total_supply;

    pool.lsp_supply.decrease_supply(coin::into_balance(lsp));

    (
        coin::take(&mut pool.token_a, token_a, ctx),
        coin::take(&mut pool.token_b, token_b, ctx),
    )
}

entry fun swap_a_to_b<TA, TB> (pool: &mut Pool<TA, TB>, token_a: Coin<TA>, ctx: &mut TxContext) {

    transfer::public_transfer(
        swap_a_to_b_inner(pool, token_a, ctx),
        tx_context::sender(ctx)
    )
}

fun swap_a_to_b_inner<TA, TB> (
    pool: &mut Pool<TA, TB>,
    token_a: Coin<TA>,
    ctx: &mut TxContext
): Coin<TB> {
    let token_a_amt = token_a.value();
    assert!(token_a_amt > 0, EZeroAmount);

    let (token_a_amt, token_b_amt, _) = get_amounts(pool);
    assert!(token_a_amt > 0 && token_b_amt > 0, EReservesEmpty);

    let token_b_amt = sell_token_a(pool, token_a_amt);

    pool.token_a.join(coin::into_balance(token_a));

    coin::take(&mut pool.token_b, token_b_amt, ctx)
}

entry fun swap_b_to_a<TA, TB> (
    pool: &mut Pool<TA, TB>,
    token_b: Coin<TB>,
    ctx: &mut TxContext
) {
    transfer::public_transfer(
        swap_b_to_a_inner(pool, token_b, ctx),
        tx_context::sender(ctx)
    )
}

fun swap_b_to_a_inner<TA, TB> (
    pool: &mut Pool<TA, TB>,
    token_b: Coin<TB>,
    ctx: &mut TxContext
): Coin<TA> {
    let token_b_amt = token_b.value();
    assert!(token_b_amt > 0, EZeroAmount);

    let (token_a_amt, token_b_amt, _) = get_amounts(pool);
    assert!(token_a_amt > 0 && token_b_amt > 0, EReservesEmpty);

    let token_a_amt = sell_token_b(pool, token_b_amt);

    pool.token_b.join(coin::into_balance(token_b));

    coin::take(&mut pool.token_a, token_a_amt, ctx)
}

/// 计算售出指定数量的 Token A，会得到多少数量的 Token B
public fun sell_token_a<TA, TB>(pool: &Pool<TA, TB>, to_sell: u64): u64 {
    let (token_a_amt, token_b_amt, _) = get_amounts(pool);
    calc_output_amount(
        to_sell,
        token_a_amt,
        token_b_amt,
        pool.fee_percent
    )
}

/// 计算售出指定数量的 Token B，会得到多少数量的 Token A
public fun sell_token_b<TA, TB>(pool: &Pool<TA, TB>, to_sell: u64): u64 {
    let (token_a_amt, token_b_amt, _) = get_amounts(pool);
    calc_output_amount(
        to_sell,
        token_b_amt,
        token_a_amt,
        pool.fee_percent
    )
}

/// Get most used values in a handy way:
/// - amount of token a
/// - amount of token b
/// - total supply of LSP
public fun get_amounts<TA, TB>(pool: &Pool<TA, TB>): (u64, u64, u64) {
    (
        pool.token_a.value(),
        pool.token_b.value(),
        balance::supply_value(&pool.lsp_supply),
    )
}

public fun calc_output_amount(
    input_amount: u64,
    input_reserve: u64,
    output_reserve: u64,
    fee_percent: u64
): u64 {
    let (
        input_amount,
        input_reserve,
        output_reserve,
        fee_percent
    ) = (
        (input_amount as u128),
        (input_reserve as u128),
        (output_reserve as u128),
        (fee_percent as u128),
    );

    // 计算手续费后的输入数量
    let input_with_fee = input_amount * FEE_SCALING / (FEE_SCALING - fee_percent);

    // 根据公式 (x + dx) * (y - dy) = k
    // 得到 dy = y - k / (x + dx)
    let total = input_reserve * output_reserve;
    let output_amount = output_reserve - total / (input_reserve + input_with_fee);

    (output_amount as u64)
}