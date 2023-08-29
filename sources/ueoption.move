module otp::ueoption {
    use std::signer;
    use std::timestamp;
    use std::string::{Self, String};

    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::vector;
    use aptos_std::string_utils;

    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    // use aptos_token_objects::property_map;

    use pyth::pyth;
    use pyth::price::Price;
    use pyth::price_identifier;

    /**
     *  constants
     */
    const RA_SEED: vector<u8> = b"RA_UEOPTION";

    // available assets
    const ASSET_BTC: vector<u8> = b"BTC";

    // Option states
    const OPTION_STATE_CANCELED: u8 = 0;
    const OPTION_STATE_INITIALIZED: u8 = 1;
    const OPTION_STATE_EXERCISED: u8 = 2;
    const OPTION_STATE_EXPIRED: u8 = 3;

    /**
     *  errors
     */
    const ENotAdmin: u64 = 0;
    const EUnsupportedAsset: u64 = 1;
    const EOptionNotFound: u64 = 2;
    const EAccountHasNotRegisteredAptosCoin: u64 = 3;
    const EInternalError: u64 = 1000;

    /**
     *  structs
     */

    struct ProtocolOption has key, drop {
        strike: u64,
        premium: u64,
        // epoch timestamp in milliseconds
        expiry_ms: u64,
        state: u8,
        issuer_address: address,
        amount: u64,
    }

    // better name needed than State
    struct Repository has key {
        options: SimpleMap<u64, vector<address>>,
        default_expiry_ms: u64,
        signer_cap: SignerCapability
    }

    //=
    //= entry function
    //=

    public entry fun initialize(admin: &signer, default_expiry_ms: u64) {
        assert_admin(signer::address_of(admin));

        let (ra, signer_cap) = account::create_resource_account(admin, RA_SEED);
        move_to(
            &ra,
            Repository {
                options: simple_map::create(),
                default_expiry_ms,
                signer_cap,
            }
        );
    }

    public entry fun underwrite(issuer: &signer) acquires Repository {
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        let ra_signer = account::create_signer_with_capability(&repo.signer_cap);
        let issuer_address = signer::address_of(issuer);
        assert!(
            coin::is_account_registered<AptosCoin>(issuer_address),
            EAccountHasNotRegisteredAptosCoin // AptosCoin is required to act as base coin for trading
        );
        let expiry_ms = timestamp::now_microseconds() + repo.default_expiry_ms; // TODO: floor to start of the day

        let bucket_key = get_day_bucket(expiry_ms);
        if (simple_map::contains_key(&repo.options, &bucket_key)) {
            let expiry_bucket = simple_map::borrow_mut(&mut repo.options, &bucket_key);
            let option_object = create_option_object(
                &ra_signer, issuer_address, expiry_ms, vector::length(expiry_bucket) + 1
            );
            vector::push_back(
                expiry_bucket,
                // FIXME is this address of an object or ProtocolOption
                object::object_address<ProtocolOption>(&option_object)
            );

            // object::transfer(&ra_signer, option_object, issuer_address);
        } else {
            let option_object = create_option_object(
                &ra_signer, issuer_address, expiry_ms, 1
            );
            let new_expiry_bucket = vector::empty();
            vector::push_back(
                &mut new_expiry_bucket,
                // FIXME is this address of an object or ProtocolOption
                object::object_address<ProtocolOption>(&option_object)
            );
            simple_map::add(&mut repo.options, bucket_key, new_expiry_bucket);

            // object::transfer(&ra_signer, option_object, issuer_address);
        };
    }

    public entry fun list(holder: &signer, option_address: address) acquires Repository, ProtocolOption {
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        assert!(
            exists<ProtocolOption>(option_address),
            EOptionNotFound
        );

        let option = borrow_global<ProtocolOption>(option_address);
        let expiry_bucket = simple_map::borrow(&mut repo.options, &get_day_bucket(option.expiry_ms));
        assert!(
            vector::contains(expiry_bucket, &option_address),
            EInternalError
        );

        let option_object = object::address_to_object<ProtocolOption>(option_address);
        // FIXME add fees
        object::transfer(
            holder,
            option_object,
            ra_address,
        );
    }

    public entry fun buy(buyer: &signer, option_address: address) acquires Repository, ProtocolOption {
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        assert!(
            exists<ProtocolOption>(option_address),
            EOptionNotFound
        );

        let option = borrow_global<ProtocolOption>(option_address);
        let expiry_bucket = simple_map::borrow(&mut repo.options, &get_day_bucket(option.expiry_ms));
        assert!(
            vector::contains(expiry_bucket, &option_address),
            EInternalError
        );

        // FIXME add fees
        let option_object = object::address_to_object<ProtocolOption>(option_address);
        coin::transfer<AptosCoin>(buyer, option.issuer_address, option.premium);
        let ra_signer = account::create_signer_with_capability(&repo.signer_cap);
        object::transfer(
            &ra_signer,
            option_object,
            signer::address_of(buyer)
        );
    }
    // public entry fun cancel() {}

    /// Updates the Pyth price feeds using the given pyth_update_data, and then returns
    /// the BTC/USD price.
    ///
    /// https://github.com/pyth-network/pyth-js/tree/main/pyth-aptos-js should be used to
    /// fetch the pyth_update_data off-chain and pass it in. More information about how this
    /// works can be found at https://docs.pyth.network/documentation/pythnet-price-feeds/aptos
    public fun get_asset_price(asset: vector<u8>): Price {
        // let coins = coin::withdraw(admin, pyth::get_update_fee(&pyth_update_data));
        // pyth::update_price_feeds(pyth_update_data, coins);

        let asset_id = if (asset == ASSET_BTC) {
            x"f9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b"
        } else {
            x"00"
        };
        assert!(asset_id != x"00", EUnsupportedAsset);

        pyth::get_price(price_identifier::from_byte_vec(asset_id))
    }

    //=
    //= logic helper function
    //=

    inline fun derive_option_seed(asset: String, expiry_ms: u64, num: u64): vector<u8> {
        let s = copy asset;
        string::append(&mut s, string::utf8(b":"));
        string::append(&mut s, string_utils::to_string<u64>(&expiry_ms));
        string::append(&mut s, string::utf8(b":"));
        string::append(&mut s, string_utils::to_string<u64>(&num));
        *string::bytes(&s)
    }

    // inline fun calculate_premium() {}

    inline fun get_resource_account_address(): address {
        account::create_resource_address(&@admin_address, RA_SEED)
    }

    inline fun get_day_bucket(expiry_ms: u64): u64 {
        // 1_000_000 microseconds in second
        expiry_ms / (24 * 60 * 60 * 1000000) // FIXME make a constant
    }

    inline fun create_option_object(creator: &signer, issuer_address: address, expiry_ms: u64, option_num: u64): Object<ProtocolOption> {
        // let transfer_ref = object::generate_transfer_ref(&token_constructor_ref);
        // object::transfer_with_ref(
        //     object::generate_linear_transfer_ref(&transfer_ref),
        //     adopter_address,
        // );
        let seed = derive_option_seed(string::utf8(b"BTC"), expiry_ms, option_num);
        let constructor_ref = object::create_named_object(
            creator,
            seed
        );
        let object_signer = object::generate_signer(&constructor_ref);

        // FIXME decide what to use struct props, or wallet friendly property map
        // let properties = property_map::prepare_input(vector[], vector[], vector[]);
        // property_map::init(&constructor_ref, properties);
        // let prop_mut_ref = property_map::generate_mutator_ref(&constructor_ref);
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"strike"),
        //     1
        // );
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"premium"),
        //     1
        // );
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"expiry_ms"),
        //     timestamp::now_microseconds() + DEFAULT_EXPIRY_MS
        // );
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"state"),
        //     OPTION_STATE_INITIALIZED
        // );
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"issuer_address"),
        //     issuer_address
        // );
        // property_map::add_typed(
        //     &prop_mut_ref,
        //     string::utf8(b"amount"),
        //     1
        // );

        move_to(
            &object_signer,
            ProtocolOption {
                strike: 1, // FIXME
                premium: 1, // FIXME
                expiry_ms,
                state: OPTION_STATE_INITIALIZED,
                issuer_address,
                amount: 1,
            }
        );

        object::object_from_constructor_ref<ProtocolOption>(&constructor_ref)
    }

    //=
    //= assertions
    //=

    inline fun assert_admin(address: address) {
        assert!(
            address == @admin_address,
            ENotAdmin
        );
    }

    //=
    //= tests
    //=
    #[test(admin = @admin_address)]
    fun test_initialize_success(admin: &signer) {
        let admin_address = signer::address_of(admin);

        initialize(admin, 7 * 24 * 60 * 60 * 1000000);
        let expected_ra_addr = account::create_resource_address(&admin_address, RA_SEED);
        assert!(account::exists_at(expected_ra_addr), 0);
    }

    #[test()]
    fun test_derive_option_seed() {
        assert!(
            derive_option_seed(string::utf8(b"BTC"), 1, 1) == b"BTC:1:1",
            0
        );
        assert!(
            derive_option_seed(string::utf8(b"BTC"), 10, 111) == b"BTC:10:111",
            0
        );
        assert!(
            derive_option_seed(string::utf8(b"BTC"), 1230001000200030004, 235) == b"BTC:1230001000200030004:235",
            0
        );
    }

    #[test(admin = @admin_address)]
    fun test_underwrite_success(admin: &signer) acquires Repository, ProtocolOption {
        let aptos_framework = account::create_account_for_test(@aptos_framework);

        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let default_expiry_ms = 100;
        initialize(admin, default_expiry_ms);

        let now = 10;
        timestamp::fast_forward_seconds(now);

        let issuer_address = @0xA;
        let issuer = account::create_account_for_test(issuer_address);
        coin::register<AptosCoin>(&issuer);
        underwrite(&issuer);

        let ra_address = get_resource_account_address();
        let expected_new_option_address = object::create_object_address(&ra_address, b"BTC:10000100:1");
        let created_option = borrow_global<ProtocolOption>(expected_new_option_address);

        assert!(
            created_option.state == OPTION_STATE_INITIALIZED,
            0
        );
        assert!(
            created_option.strike == 1,
            0
        );
        assert!(
            created_option.premium == 1,
            0
        );
        assert!(
            created_option.expiry_ms == now * 1000000 + default_expiry_ms,
            0
        );
        assert!(
            created_option.issuer_address == issuer_address,
            0
        );

        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            object::owner<ProtocolOption>(created_option_object) == ra_address,
            0 // assert listed in platform escrow resource account
        );
        // assert!(
        //     object::owner<ProtocolOption>(created_option_object) == issuer_address,
        //     0 // assert issuer own the option
        // );
    }

    #[test(admin = @admin_address)]
    fun test_buy_success(admin: &signer) acquires Repository, ProtocolOption {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        let issuer_address = @0xA;
        let buyer_address = @0xB;
        let issuer = account::create_account_for_test(issuer_address);
        let buyer = account::create_account_for_test(buyer_address);
        coin::register<AptosCoin>(&issuer);
        coin::register<AptosCoin>(&buyer);
        aptos_coin::mint(&aptos_framework, buyer_address, 10);

        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let now = 10;
        timestamp::fast_forward_seconds(now);

        let option_expiry_ms = 1000000;
        initialize(admin, option_expiry_ms);
        underwrite(&issuer);

        let ra_address = get_resource_account_address();
        let expected_new_option_address = object::create_object_address(&ra_address, b"BTC:11000000:1");
        buy(&buyer, expected_new_option_address);

        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            object::owner<ProtocolOption>(created_option_object) == buyer_address,
            0
        );
        assert!(
            coin::balance<AptosCoin>(buyer_address) == 9,
            0
        );
        assert!(
            coin::balance<AptosCoin>(issuer_address) == 1,
            0
        );

        // tear down
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // #[test()]
    // fun test_get_asset_price_btc() {
    //     debug::print(&@pyth);
    //     debug::print(&@deployer);
    //     let deployer = account::create_signer_with_capability(
    //         &account::create_test_signer_cap(
    //             @deployer
    //         )
    //     );
    //     let (_, pyth_signer_capability) = account::create_resource_account(&deployer, b"pyth");
    //     pyth::init_test(
    //         pyth_signer_capability,
    //         500,
    //         1,
    //         x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
    //         vector[],
    //         50
    //     );
    //
    //     debug::print(&get_asset_price(ASSET_BTC));
    // }

    // #[test()]
    // #[expected_failure(abort_code = 0x1, location = Self)]
    // fun test_get_asset_price_unsupported_asset() {
    //     let deployer = account::create_signer_with_capability(
    //         &account::create_test_signer_cap(
    //             @deployer
    //         )
    //     );
    //     let (_, pyth_signer_capability) = account::create_resource_account(&deployer, b"pyth");
    //     pyth::init_test(
    //         pyth_signer_capability,
    //         500,
    //         1,
    //         x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
    //         vector[],
    //         50
    //     );
    //
    //     get_asset_price(b"WTF");
    // }
}
