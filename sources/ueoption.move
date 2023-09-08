// TODO rename to remove the ue suffix 
module otp::ueoption {
    use std::signer;
    use std::timestamp;
    use std::option;
    use std::string::{Self, String};

    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::vector;
    use aptos_std::string_utils;

    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{Self, Metadata};

    use aptos_token_objects::token;
    use aptos_token_objects::collection;
    use aptos_token_objects::property_map;

    use pyth::pyth;
    use pyth::price::Price;
    use pyth::price_identifier;

    #[test_only]
    friend otp::ueoption_test;

    /**
     *  constants
     */

    // available assets
    const ASSET_BTC: vector<u8> = b"BTC";
    const RA_SEED: vector<u8> = b"RA_UEOPTION";

    // Option states
    const OPTION_STATE_CANCELED: u8 = 0;
    const OPTION_STATE_INITIALIZED: u8 = 1;
    const OPTION_STATE_EXERCISED: u8 = 2;
    const OPTION_STATE_EXPIRED: u8 = 3;

    // collection & tokens confit
    const COLLECTION_NAME: vector<u8> = b"OTP";
    const COLLECTION_DESCRIPTION: vector<u8> = b"the option trading protocol collection";
    const COLLECTION_URI: vector<u8> = b"FIXME";
    const LE_TOKEN_DESCRIPTION: vector<u8> = b"the option trading protocol locked expiration option";
    const LE_TOKEN_URI: vector<u8> = b"FIXME";
    // option token properties
    const OPTION_PROPERTY_STATE_KEY: vector<u8> = b"state";
    const OPTION_PROPERTY_EXPIRY_MS_KEY: vector<u8> = b"expiry_ms";
    const OPTION_PROPERTY_PREMIUM_KEY: vector<u8> = b"premium";
    const OPTION_PROPERTY_ISSUER_ADDRESS_KEY: vector<u8> = b"issuer_address";

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
        property_mutator_ref: property_map::MutatorRef,
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
        // strike: u64,
        // premium: u64,
        // // epoch timestamp in milliseconds
        // expiry_ms: u64,
        // state: u8,
        // issuer_address: address,
        // amount: u64,
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
        create_collection(&ra);
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
        let issuer_address = signer::address_of(issuer);
        assert!(
            coin::is_account_registered<AptosCoin>(issuer_address),
            EAccountHasNotRegisteredAptosCoin // AptosCoin is required to act as base coin for trading
        );
        let repo = borrow_global_mut<Repository>(ra_address);
        let expiry_ms = timestamp::now_microseconds() + repo.default_expiry_ms; // TODO: floor to start of the day

        let ra_signer = account::create_signer_with_capability(&repo.signer_cap);
        let bucket_key = get_day_bucket(expiry_ms);
        if (simple_map::contains_key(&repo.options, &bucket_key)) {
            let expiry_bucket = simple_map::borrow_mut(&mut repo.options, &bucket_key);
            let option_object = create_option_object(
                &ra_signer, issuer_address, expiry_ms
            );
            vector::push_back(
                expiry_bucket,
                // FIXME is this address of an object or ProtocolOption
                object::object_address<ProtocolOption>(&option_object)
            );

            // object::transfer(&ra_signer, option_object, issuer_address);
        } else {
            let option_object = create_option_object(
                &ra_signer, issuer_address, expiry_ms
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

    // public entry fun list(holder: &signer, option_address: address) acquires Repository, ProtocolOption {
    //     let ra_address = get_resource_account_address();
    //     let repo = borrow_global_mut<Repository>(ra_address);
    //     assert!(
    //         exists<ProtocolOption>(option_address),
    //         EOptionNotFound
    //     );
    //
    //     let option = borrow_global<ProtocolOption>(option_address);
    //     let expiry_bucket = simple_map::borrow(&mut repo.options, &get_day_bucket(option.expiry_ms));
    //     assert!(
    //         vector::contains(expiry_bucket, &option_address),
    //         EInternalError
    //     );
    //
    //     let option_object = object::address_to_object<ProtocolOption>(option_address);
    //     // FIXME add fees
    //     object::transfer(
    //         holder,
    //         option_object,
    //         ra_address,
    //     );
    // }

    public entry fun buy(buyer: &signer, option_address: address) acquires Repository, ProtocolOption {
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        assert!(
            exists<ProtocolOption>(option_address),
            EOptionNotFound
        );

        // let option = borrow_global<ProtocolOption>(option_address);
        let option_object = object::address_to_object<ProtocolOption>(option_address);

        let option_expiry_ms = property_map::read_u64(
            &option_object,
            &string::utf8(OPTION_PROPERTY_EXPIRY_MS_KEY)
        );
        let expiry_bucket = simple_map::borrow(&mut repo.options, &get_day_bucket(option_expiry_ms));
        assert!(
            vector::contains(expiry_bucket, &option_address),
            EInternalError
        );

        // FIXME add fees
        let option_premium = property_map::read_u64(
            &option_object,
            &string::utf8(OPTION_PROPERTY_PREMIUM_KEY)
        );
        let option_issuer_address = property_map::read_address(
            &option_object,
            &string::utf8(OPTION_PROPERTY_ISSUER_ADDRESS_KEY)
        );
        coin::transfer<AptosCoin>(buyer, option_issuer_address, option_premium);

        let option_token = borrow_global<ProtocolOption>(option_address);
        primary_fungible_store::mint(
            &option_token.mint_ref,
            signer::address_of(buyer),
            1
        )
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
    
    fun get_asset_decimals(asset: vector<u8>): u8 {
        let number_of_decimals: u8 = if (asset == ASSET_BTC) {
            // TODO: dinamically check how many digits on right before asset will be single digit
            // e.g 25900 BTC has 4 digits befor it became 2, thus option has 4 decimals
            4
        } else {
            // 32 is max decimls possible in Aptos
            33
        };
        assert!(number_of_decimals != 33, EUnsupportedAsset);

        number_of_decimals
    }

    fun get_asset_icon_uri(asset: vector<u8>): String {
        let icon_uri = if (asset == ASSET_BTC) {
            b"FIXME: ADD BTC ICON"
        } else {
            b""
        };
        assert!(icon_uri != b"", EUnsupportedAsset);

        string::utf8(icon_uri)
    }

    //=
    //= helper function
    //=

    public(friend) fun derive_option_seed(asset: String, expiry_ms: u64): vector<u8> {
        let s = copy asset;
        string::append(&mut s, string::utf8(b":"));
        string::append(&mut s, string_utils::to_string<u64>(&expiry_ms));
        *string::bytes(&s)
    }

    // fun calculate_premium() {}

    public(friend) fun get_resource_account_address(): address {
        account::create_resource_address(&@admin_address, RA_SEED)
    }

    fun get_day_bucket(expiry_ms: u64): u64 {
        // 1_000_000 microseconds in second
        expiry_ms / (24 * 60 * 60 * 1000000) // FIXME make a constant
    }

    fun create_collection(creator: &signer) {
        collection::create_unlimited_collection(
            creator,
            string::utf8(COLLECTION_DESCRIPTION),
            string::utf8(COLLECTION_NAME),
            option::none(), // FIXME what roaylty to set?
            string::utf8(COLLECTION_URI),
        );
    }

    fun create_option_object(creator: &signer, issuer_address: address, expiry_ms: u64): Object<ProtocolOption> {
        let asset = b"BTC";
        let token_name = string::utf8(derive_option_seed(string::utf8(asset), expiry_ms));
        let constructor_ref = token::create_named_token(
            creator,
            string::utf8(COLLECTION_NAME),
            string::utf8(LE_TOKEN_DESCRIPTION),
            token_name,
            option::none(),
            string::utf8(LE_TOKEN_URI),
        );
        let object_signer = object::generate_signer(&constructor_ref);

        let property_mutator_ref = property_map::generate_mutator_ref(&constructor_ref);

        let properties = property_map::prepare_input(vector[], vector[], vector[]);
        property_map::init(&constructor_ref, properties);
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"strike"),
            1
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"premium"),
            1
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"expiry_ms"),
            expiry_ms
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(OPTION_PROPERTY_STATE_KEY),
            OPTION_STATE_INITIALIZED
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"issuer_address"),
            issuer_address
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"amount"),
            1
        );

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            token_name,
            string::utf8(b"OTC"), // FIXME: need a system for options symbols, max length 10
            get_asset_decimals(asset),
            get_asset_icon_uri(asset),
            string::utf8(COLLECTION_URI),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        move_to(
            &object_signer,
            ProtocolOption {
                property_mutator_ref,
                mint_ref,
                burn_ref,
            }
        );

        object::object_from_constructor_ref<ProtocolOption>(&constructor_ref)
    }

    //=
    //= getters
    //=

    fun option_address(expiry_ms: u64) {
        let token_name = derive_option_seed(string::utf8(b"BTC"), expiry_ms);
        let ra_address = get_resource_account_address();
        token::create_token_address(
            &ra_address, // FIXME could be wron, and address need to be gen from capability
            &string::utf8(COLLECTION_NAME),
            &string::utf8(token_name),
        );
    }

    // public(friend) fun get_option_owned_amount(owner_address: address, option_address: address): u64 {
    //     let option_object = object::address_to_object<ProtocolOption>(option_address);
    //     let metadata = object::convert<ProtocolOption, Metadata>(option_object);
    //     let store = primary_fungible_store::ensure_primary_store_exists(owner_address, metadata);
    //     fungible_asset::balance(store)
    // }

    //=
    //= assertions
    //=

    fun assert_admin(address: address) {
        assert!(
            address == @admin_address,
            ENotAdmin
        );
    }
}

/*

--- tests ---

*/

#[test_only]
module otp::ueoption_test {
    use otp::ueoption::{Self, ProtocolOption};

    use std::signer;
    use std::timestamp;
    use std::string::{Self};

    use aptos_framework::coin;
    use aptos_framework::object::{Self};
    use aptos_framework::account::{Self};
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin::{BurnCapability, MintCapability};
    use aptos_framework::primary_fungible_store;

    use aptos_token_objects::token;
    use aptos_token_objects::property_map;

    use pyth::pyth;
    use pyth::price_info;
    use pyth::price_feed;
    use pyth::price_identifier;
    use pyth::i64;
    use pyth::price;
    use pyth::pyth_test;
    use aptos_std::debug;
    use wormhole::wormhole;

    // FIXME: why it is required?
    const RA_SEED: vector<u8> = b"RA_UEOPTION";
    
    const ETestExpectationFailure: u64 = 0;

    #[test(admin = @admin_address)]
    fun test_initialize_success(admin: &signer) {
        let admin_address = signer::address_of(admin);

        ueoption::initialize(admin, 7 * 24 * 60 * 60 * 1000000);
        let expected_ra_addr = account::create_resource_address(&admin_address, b"RA_UEOPTION");
        assert!(account::exists_at(expected_ra_addr), 0);
    }

    #[test()]
    fun test_derive_option_seed() {
        assert!(
            ueoption::derive_option_seed(string::utf8(b"BTC"), 1) == b"BTC:1",
            0
        );
        assert!(
            ueoption::derive_option_seed(string::utf8(b"BTC"), 10) == b"BTC:10",
            0
        );
        assert!(
            ueoption::derive_option_seed(string::utf8(b"BTC"), 1230001000200030004) == b"BTC:1230001000200030004",
            0
        );
    }

    #[test(admin = @admin_address)]
    fun test_underwrite_success(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let default_expiry_ms = 100;
        ueoption::initialize(admin, default_expiry_ms);

        let now = 10;
        timestamp::fast_forward_seconds(now);

        let issuer_address = @0xA;
        let issuer = account::create_account_for_test(issuer_address);
        coin::register<AptosCoin>(&issuer);

        ueoption::underwrite(&issuer);

        let ra_address = ueoption::get_resource_account_address();
        let expected_new_option_address = token::create_token_address(
            &ra_address,
            &string::utf8(b"OTP"),
            &string::utf8(b"BTC:10000100")
        );

        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            property_map::read_u8(&created_option_object, &string::utf8(b"state")) == 1,
            ETestExpectationFailure // state is 1, initialized
        );
        assert!(
            property_map::read_address(&created_option_object, &string::utf8(b"issuer_address")) == issuer_address,
            ETestExpectationFailure 
        );
        assert!(
            property_map::read_u64(&created_option_object, &string::utf8(b"strike")) == 1,
            ETestExpectationFailure 
        );
        assert!(
            property_map::read_u64(&created_option_object, &string::utf8(b"premium")) == 1,
            ETestExpectationFailure 
        );
        assert!(
            object::is_owner(created_option_object, ra_address),
            ETestExpectationFailure  // option token object owner by the resource account
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    fun test_buy_success(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

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
        ueoption::initialize(admin, option_expiry_ms);
        ueoption::underwrite(&issuer);

        let ra_address = ueoption::get_resource_account_address();
        let expected_new_option_address = token::create_token_address(
            &ra_address,
            &string::utf8(b"OTP"),
            &string::utf8(b"BTC:11000000")
        );
        ueoption::buy(&buyer, expected_new_option_address);

        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            primary_fungible_store::balance(buyer_address, created_option_object) == 1,
            ETestExpectationFailure
        );
        assert!(
            coin::balance<AptosCoin>(buyer_address) == 9,
            ETestExpectationFailure
        );
        assert!(
            coin::balance<AptosCoin>(issuer_address) == 1,
            ETestExpectationFailure
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_get_asset_price_btc(aptos_framework: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        timestamp::update_global_time_for_test_secs(1000);

        setup_price_oracle();

        pyth_test::update_cache_for_test(
            vector[
                // struct PriceInfo has copy, drop, store {
                //     attestation_time: u64,
                //     arrival_time: u64,
                //     price_feed: PriceFeed {
                //         price_identifier: PriceIdentifier,
                //         price: Price {
                //           price: I64 {
                //             negative: bool,
                //             mmagnitude: u64,
                //           },
                //           conf: u64,
                //           expo: I64,
                //           timestamp: u64,
                //         },
                //         ema_price: Price
                //     },
                // }
                price_info::new(
                    timestamp::now_seconds() - 1, 
                    timestamp::now_seconds() - 2, 
                    price_feed::new(
                        price_identifier::from_byte_vec(x"f9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b"),
                        price::new(
                            i64::new(2594760112405, false),
                            830112404,
                            i64::new(8, true),
                            timestamp::now_seconds() - 1,
                        ),
                        price::new(
                            i64::new(2595868730000, false),
                            782335890,
                            i64::new(8, true),
                            timestamp::now_seconds() - 1,
                        ),
                    ),
                ),
            ]
        );

        let btc_price = ueoption::get_asset_price(b"BTC"); 
        assert!(
             i64::get_magnitude_if_positive(&price::get_price(&btc_price)) == 2594760112405,
            0
        );

        timestamp::fast_forward_seconds(60);

        pyth_test::update_cache_for_test(
            vector[
                price_info::new(
                    timestamp::now_seconds() - 1, 
                    timestamp::now_seconds() - 2, 
                    price_feed::new(
                        price_identifier::from_byte_vec(x"f9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b"),
                        price::new(
                            i64::new(2600150002888, false),
                            830112404,
                            i64::new(8, true),
                            timestamp::now_seconds() - 1,
                        ),
                        price::new(
                            i64::new(2597899730000, false),
                            782335890,
                            i64::new(8, true),
                            timestamp::now_seconds() - 1,
                        ),
                    ),
                ),
            ]
        );

        let btc_price = ueoption::get_asset_price(b"BTC"); 
        assert!(
             i64::get_magnitude_if_positive(&price::get_price(&btc_price)) == 2600150002888,
            0
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test()]
    #[expected_failure(abort_code = 0x1, location = otp::ueoption)]
    fun test_get_asset_price_unsupported_asset() {
        let (_, burn_cap, mint_cap) = setup_test_framework();
        setup_price_oracle();

        ueoption::get_asset_price(b"WTF");

        teardown_test_framework(burn_cap, mint_cap);
    }

    //=
    //= test setup and teardown
    //=

    fun setup_test_framework(): (signer, BurnCapability<AptosCoin>, MintCapability<AptosCoin>) {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        (aptos_framework, burn_cap, mint_cap)
    }

    fun setup_price_oracle() {
        let deployer = account::create_signer_with_capability(
            &account::create_test_signer_cap(@deployer)
        );
        let (_ra, pyth_signer_capability) = account::create_resource_account(&deployer, b"pyth");
        pyth::init_test(
            pyth_signer_capability,
            500, // stale price threshold
            1, // update fee
            x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
            vector[],
            50
        );
    }

    fun teardown_test_framework(burn_cap: BurnCapability<AptosCoin>, mint_cap: MintCapability<AptosCoin>) {
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
