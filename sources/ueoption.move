// TODO rename to remove the ue suffix
module otp::ueoption {
    use std::signer;
    use std::timestamp;
    use std::option;
    use std::string::{Self, String};

    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::vector;
    use aptos_std::math64;
    use aptos_std::string_utils;

    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset;
    use aptos_framework::managed_coin;

    use aptos_token_objects::token;
    use aptos_token_objects::royalty;
    use aptos_token_objects::collection;
    use aptos_token_objects::property_map;

    use otp::date;

    use pyth::pyth;
    use pyth::price::Price;
    use pyth::price_identifier;

    #[test_only]
    friend otp::ueoption_test;

    /**
     *  constants
     */

    // available assets
    // all (bases) assets have USD quote currency
    /// Wormhole Wrapped Bitcoin from Ethereum WBTC/USD
    /// https://aptoscan.com/coin/0xae478ff7d83ed072dbc5e264250e67ef58f57c99d89b447efd8a0a2e8b2be76e::coin::T
    const ASSET_WBTC: vector<u8> = b"WBTC";
    /// Native Aptos coin, APT/USD
    const ASSET_APT: vector<u8> = b"APT";

    const RA_SEED: vector<u8> = b"RA_UEOPTION";

    // Option types
    const OPTION_CALL: u8 = 1;
    const OPTION_PUT: u8 = 2;

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
    const OPTION_PROPERTY_MULTIPLIER_KEY: vector<u8> = b"multiplier";

    /**
     *  errors
     */
    const ENotAdmin: u64 = 0;
    const EUnsupportedAsset: u64 = 1;
    const EOptionNotFound: u64 = 2;
    const EOptionDuplicate: u64 = 500;
    const EOptionNotEnougSupply: u64 = 501;
    const EInternalError: u64 = 1000;
    const ENotImplemented: u64 = 1001;

    /**
     *  structs
     */

    struct ProtocolOption has key, drop {
        property_mutator_ref: property_map::MutatorRef,
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
    }

    struct Repository has key {
        /// list of active options
        /// SimpleMap<time bucket, start of the day UTC, vector of token names>
        options: SimpleMap<u64, vector<String>>,
        /// default expiry for options, deprecated, do not use
        default_expiry_ms: u64,
        /// fees in form of royalties, range from 0 to 100
        sell_fee: u64,
        signer_cap: SignerCapability
    }
    
    //=
    //= Temporary
    //=
    
    // replace with USDC
    struct UsdCoin has key {}

    //=
    //= entry function
    //=

    public entry fun initialize(admin: &signer, default_expiry_ms: u64) {
        assert_admin(signer::address_of(admin));

        let (ra, signer_cap) = account::create_resource_account(admin, RA_SEED);
        create_collection(&ra);

        // register coins for all supported assets
        coin::register<AptosCoin>(&ra);
        managed_coin::initialize<UsdCoin>(admin, b"UsdStubCoin", b"USD", 6, false);

        move_to(
            &ra,
            Repository {
                options: simple_map::create(),
                default_expiry_ms,
                signer_cap,
                sell_fee: 0 // no fees, to incentivize trades
            }
        );
    }

    public entry fun underwrite(
        issuer: &signer,
        asset: vector<u8>,
        supply_amount: u64,
        multiplier: u64,
        premium: u64
    ) acquires Repository {
        collaterize_asset(issuer, asset, supply_amount);

        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        let expiry_ms = timestamp::now_microseconds() + repo.default_expiry_ms; // TODO: floor to start of the day, TODO: replace with argument, and checks for valid dates weekly, daily, monthly probably
        let ra_signer = account::create_signer_with_capability(&repo.signer_cap);
        let bucket_key = get_day_bucket(expiry_ms);
        let issuer_address = signer::address_of(issuer);
        let option_name = create_option_object(
            &ra_signer, asset, issuer_address, repo.sell_fee, expiry_ms, supply_amount, multiplier, premium
        );
        if (simple_map::contains_key(&repo.options, &bucket_key)) {
            let expiry_bucket = simple_map::borrow_mut(&mut repo.options, &bucket_key);
            vector::push_back(
                expiry_bucket,
                option_name
            );
        } else {
            let new_expiry_bucket = vector::empty();
            vector::push_back(
                &mut new_expiry_bucket,
                option_name
            );
            simple_map::add(&mut repo.options, bucket_key, new_expiry_bucket);
        };
    }

    public entry fun buy(buyer: &signer, option_name: String, amount: u64) acquires Repository, ProtocolOption {
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        let option_address = get_option_address_with_name(&option_name);
        assert!(
            exists<ProtocolOption>(option_address),
            EOptionNotFound
        );

        let option_object = object::address_to_object<ProtocolOption>(option_address);

        let option_expiry_ms = property_map::read_u64(
            &option_object,
            &string::utf8(OPTION_PROPERTY_EXPIRY_MS_KEY)
        );
        let expiry_bucket = simple_map::borrow(&mut repo.options, &get_day_bucket(option_expiry_ms));
        assert!(
            vector::contains(expiry_bucket, &option_name),
            EInternalError
        );

        let option_premium = property_map::read_u64(
            &option_object,
            &string::utf8(OPTION_PROPERTY_PREMIUM_KEY)
        );
        let option_issuer_address = property_map::read_address(
            &option_object,
            &string::utf8(OPTION_PROPERTY_ISSUER_ADDRESS_KEY)
        );
        let total_cost = option_premium * amount;
        coin::transfer<UsdCoin>(buyer, option_issuer_address, total_cost);

        let option_multiplier = property_map::read_u64(
            &option_object,
            &string::utf8(OPTION_PROPERTY_MULTIPLIER_KEY)
        );
        let option_token = borrow_global<ProtocolOption>(option_address);
        primary_fungible_store::mint(
            &option_token.mint_ref,
            signer::address_of(buyer),
            amount * option_multiplier
        )
    }
    // public entry fun cancel() {}

    /// Updates the Pyth price feeds using the given pyth_update_data, and then returns
    /// the BTC/USD price.
    ///
    /// https://github.com/pyth-network/pyth-js/tree/main/pyth-aptos-js should be used to
    /// fetch the pyth_update_data off-chain and pass it in. More information about how this
    /// works can be found at https://docs.pyth.network/documentation/pythnet-price-feeds/aptos
    ///
    /// list of price feeds https://pyth.network/developers/price-feed-ids
    public fun get_asset_price(asset: vector<u8>): Price {
        // let coins = coin::withdraw(admin, pyth::get_update_fee(&pyth_update_data));
        // pyth::update_price_feeds(pyth_update_data, coins);

        let asset_id = if (asset == ASSET_WBTC) {
            // WBTC(ethereum)/USD
            x"ea0459ab2954676022baaceadb472c1acc97888062864aa23e9771bae3ff36ed"
        } else if (asset == ASSET_APT) {
            // APT/USD
            x"44a93dddd8effa54ea51076c4e851b6cbbfd938e82eb90197de38fe8876bb66e"
        } else {
            x"00"
        };
        assert!(asset_id != x"00", EUnsupportedAsset);

        pyth::get_price(price_identifier::from_byte_vec(asset_id))
    }

    fun get_asset_decimals(asset: vector<u8>): u8 {
        // TODO: dynamically check how many digits on right before asset will be single digit
        let number_of_decimals: u8 = if (asset == ASSET_WBTC) {
            // e.g 25900 BTC has 4 digits before it became 2 USD per BTC, thus option has 4 decimals
            4
        } else if (asset == ASSET_APT) {
            // e.g 5.8 APT has 0 digits before it became 5 USD per APT, thus option has 0 decimals
            0
        } else {
            // 32 is max decimls possible in Aptos network
            33
        };
        assert!(number_of_decimals < 33, EUnsupportedAsset);

        number_of_decimals
    }

    fun get_asset_icon_uri(_asset: vector<u8>): String {
        string::utf8(b"FIXME: ADD ASSET ICONS")
    }

    //=
    //= helper function
    //=

    /// format for call QUOTE_BASE-YYYYMMDD-C-[#k][###|0][u###]
    /// format for put QUOTE_BASE-YYYYMMDD-P-[#k][###|0][u###]
    /// max token name length in Aptos is 128 bytes string
    /// see test for examples
    public(friend) fun derive_option_name(asset: String, expiry_ms: u64, call_or_put: u8, price: u64, expo: u64): vector<u8> {
        let s = copy asset;
        string::append(&mut s, string::utf8(b"_USD"));
        string::append(&mut s, string::utf8(b"-"));

        let (year, month, day) = date::timestamp_to_date(expiry_ms);
        string::append(&mut s, string_utils::to_string<u64>(&year));
        if (month < 10) {
            string::append(&mut s, string::utf8(b"0"));
            string::append(&mut s, string_utils::to_string<u64>(&month));
        } else {
            string::append(&mut s, string_utils::to_string<u64>(&month));
        };
        if (day < 10) {
            string::append(&mut s, string::utf8(b"0"));
            string::append(&mut s, string_utils::to_string<u64>(&day));
        } else {
            string::append(&mut s, string_utils::to_string<u64>(&day));
        };

        if (call_or_put == 1) {
            string::append(&mut s, string::utf8(b"-C-"));
        } else if (call_or_put == 2) {
            string::append(&mut s, string::utf8(b"-P-"));
        } else {
            abort EInternalError
        };

        let thouthands = price / math64::pow(10, expo + 3);
        let unit = (price / math64::pow(10, expo)) % 1000;
        let decimals = if (expo > 4) {
            (price % math64::pow(10, expo)) / math64::pow(10, expo - 4)
        } else {
            price % math64::pow(10, expo)
            
        };
        if (thouthands > 0) {
            string::append(&mut s, string_utils::to_string<u64>(&thouthands));
            string::append(&mut s, string::utf8(b"K"));
            string::append(&mut s, string_utils::to_string<u64>(&unit));
        } else if (unit > 0) {
            string::append(&mut s, string_utils::to_string<u64>(&unit));
            string::append(&mut s, string::utf8(b"U"));
            if (decimals < 10) {
                string::append(&mut s, string::utf8(b"000"));
            } else if (decimals < 100) {
                string::append(&mut s, string::utf8(b"00"));
            } else if (decimals < 1000) {
                string::append(&mut s, string::utf8(b"0"));
            };
            string::append(&mut s, string_utils::to_string<u64>(&decimals));
        } else if (decimals > 0) {
            if (decimals < 10) {
                string::append(&mut s, string::utf8(b"0U000"));
            } else if (decimals < 100) {
                string::append(&mut s, string::utf8(b"0U00"));
            } else if (decimals < 1000) {
                string::append(&mut s, string::utf8(b"0U0"));
            } else {
                string::append(&mut s, string::utf8(b"0U"));
            };
            string::append(&mut s, string_utils::to_string<u64>(&decimals));
        } else {
            abort EInternalError
        };

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
            option::none(), // roalties are set per token
            string::utf8(COLLECTION_URI),
        );
    }

    fun create_option_object(
        creator: &signer,
        asset: vector<u8>,
        issuer_address: address,
        royalty: u64,
        expiry_ms: u64,
        supply_amount: u64,
        multiplier: u64,
        premium: u64
    ): String {
        let token_name = string::utf8(
            derive_option_name(string::utf8(asset), expiry_ms, OPTION_CALL, 1_000, 3) // FIMXME get strike price
        );
        let royalty = if (royalty > 0) {
            let ra_address = get_resource_account_address();
            option::some(
                royalty::create(royalty, 100, ra_address)
            )
        } else {
            option::none()
        };
        let constructor_ref = token::create_named_token(
            creator,
            string::utf8(COLLECTION_NAME),
            string::utf8(LE_TOKEN_DESCRIPTION),
            token_name,
            royalty,
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
            string::utf8(OPTION_PROPERTY_MULTIPLIER_KEY),
            multiplier
        );
        property_map::add_typed(
            &property_mutator_ref,
            string::utf8(b"premium"),
            premium
        );

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some((supply_amount as u128)),
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

        token_name
    }
    
    fun collaterize_asset(asset_owner: &signer, asset: vector<u8>, amount: u64) {
        let ra_address = get_resource_account_address();
        if (asset == ASSET_WBTC) {
            abort ENotImplemented
        } else if (asset == ASSET_APT) {
            coin::transfer<AptosCoin>(
                asset_owner,
                ra_address,
                amount
            );
            return
        };

        abort EUnsupportedAsset // can't collaterize unsupported asset
    }

    //=
    //= getters
    //=

    fun get_option_address_with_name(token_name: &String): address {
        let ra_address = get_resource_account_address();
        token::create_token_address(
            &ra_address, // FIXME could be wron, and address need to be gen from capability
            &string::utf8(COLLECTION_NAME),
            token_name
        )
    }

    fun get_option_address_with_asset_expiry(asset: vector<u8>, expiry_ms: u64): address {
        let token_name = derive_option_name(string::utf8(asset), expiry_ms, OPTION_CALL, 1_000, 3); // FIXME get strike price
        get_option_address_with_name(&string::utf8(token_name))
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
    
    //=
    //= friends helpers
    //=
    
    public(friend) fun get_repo_values(): (SimpleMap<u64, vector<String>>, u64) acquires Repository {
        let ra_address = get_resource_account_address();
        let repo = borrow_global<Repository>(ra_address);
        (repo.options, repo.sell_fee)
    }
}

/*

--- tests ---

*/

#[test_only]
module otp::ueoption_test {
    use otp::ueoption::{Self, ProtocolOption};

    use std::option;
    use std::signer;
    use std::timestamp;
    use std::string::{Self};

    use aptos_framework::coin;
    use aptos_framework::object::{Self};
    use aptos_framework::account::{Self};
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin::{BurnCapability, MintCapability};
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::managed_coin;

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

    // FIXME: why it is required?
    const RA_SEED: vector<u8> = b"RA_UEOPTION";
    
    const ETestExpectationFailure: u64 = 0;

    #[test(admin = @admin_address)]
    fun test_initialize_success(admin: &signer) {
        let admin_address = signer::address_of(admin);

        ueoption::initialize(admin, 7 * 24 * 60 * 60 * 1000000);
        let expected_ra_addr = account::create_resource_address(&admin_address, b"RA_UEOPTION");
        assert!(account::exists_at(expected_ra_addr), 0);
        // TODO: test repo state
    }

    #[test(admin = @admin_address)]
    fun test_initialized_with_incentive_of_zero_sell_fees(admin: &signer) {
        let admin_address = signer::address_of(admin);

        ueoption::initialize(admin, 60_000_000);
        let (_, sell_fee) = ueoption::get_repo_values();
        assert!(
            sell_fee == 0,
            ETestExpectationFailure
        )
    }

    #[test()]
    fun test_derive_option_name() {
        let call = 1;
        let put = 2;
        let eight_decimals = 8;

        assert!(
            ueoption::derive_option_name(string::utf8(b"WBTC"), 1, call, 2580000000000, eight_decimals) == b"WBTC_USD-19700101-C-25K800",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"WBTC"), 1, put, 2580000000000, eight_decimals) == b"WBTC_USD-19700101-P-25K800",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"WBTC"), 1, put, 2580000000000, eight_decimals) == b"WBTC_USD-19700101-P-25K800",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"WBTC"), 1, put, 25800000, 3) == b"WBTC_USD-19700101-P-25K800",
            0
        );

        let date_11_aug_2023 = 1691712000;
        assert!(
            ueoption::derive_option_name(string::utf8(b"WBTC"), date_11_aug_2023, call, 2610000000000, eight_decimals) == b"WBTC_USD-20230811-C-26K100",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"APT"), date_11_aug_2023, put, 550000000, eight_decimals) == b"APT_USD-20230811-P-5U5000",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"APT"), date_11_aug_2023, put, 500000000, eight_decimals) == b"APT_USD-20230811-P-5U0000",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, put, 500010000, eight_decimals) == b"XYZ_USD-20230811-P-5U0001",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 180060000000, eight_decimals) == b"XYZ_USD-20230811-C-1K800",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 10000000, eight_decimals) == b"XYZ_USD-20230811-C-0U1000",
            0
        );

        let four_decimals = 4;
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, put, 50000, four_decimals) == b"XYZ_USD-20230811-P-5U0000",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 1, four_decimals) == b"XYZ_USD-20230811-C-0U0001",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 10, four_decimals) == b"XYZ_USD-20230811-C-0U0010",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 100, four_decimals) == b"XYZ_USD-20230811-C-0U0100",
            0
        );
        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), date_11_aug_2023, call, 1000, four_decimals) == b"XYZ_USD-20230811-C-0U1000",
            0
        );

        assert!(
            ueoption::derive_option_name(string::utf8(b"XYZ"), 1, call, 100, 0) == b"XYZ_USD-19700101-C-100U0000",
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
        aptos_coin::mint(&aptos_framework, issuer_address, 1_200);

        ueoption::underwrite(&issuer, b"APT", 1_000, 100, 250);

        let ra_address = ueoption::get_resource_account_address();
        let expected_new_option_address = token::create_token_address(
            &ra_address,
            &string::utf8(b"OTP"),
            &string::utf8(b"APT_USD-19700426-C-1U0000")
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
            property_map::read_u64(&created_option_object, &string::utf8(b"premium")) == 250,
            ETestExpectationFailure 
        );
        assert!(
            property_map::read_u64(&created_option_object, &string::utf8(b"multiplier")) == 100,
            ETestExpectationFailure 
        );
        assert!(
            object::is_owner(created_option_object, ra_address),
            ETestExpectationFailure  // option token object owner by the resource account
        );
        assert!(
            fungible_asset::maximum(created_option_object) == option::some(1_000),
            ETestExpectationFailure // max supply is 1000
        );
        assert!(
            coin::balance<AptosCoin>(issuer_address) == 200,
            ETestExpectationFailure // 1000 options with 1 to 1 collaterization * 1 APT - issuer balance 1200 APT = 200 APT
        );
        assert!(
            coin::balance<AptosCoin>(ra_address) == 1000,
            ETestExpectationFailure // resource account initial balane 0 + collaterized deposit 1000 APT = 1000 APT
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    // #[expected_failure(abort_code = 0x500, location = otp::ueoption)]
    #[expected_failure(abort_code = 0x80001, location = std::object)]
    fun test_underwrite_same_twice_failure(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let default_expiry_ms = 1000000;
        ueoption::initialize(admin, default_expiry_ms);

        let now = 1;
        timestamp::fast_forward_seconds(now);

        let issuer_address = @0xA;
        let issuer = account::create_account_for_test(issuer_address);
        coin::register<AptosCoin>(&issuer);
        aptos_coin::mint(&aptos_framework, issuer_address, 5);

        ueoption::underwrite(&issuer, b"APT", 1, 1, 1);
        ueoption::underwrite(&issuer, b"APT", 1, 1, 1);

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    fun test_buy_total_supply_success(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let now = 10;
        timestamp::fast_forward_seconds(now);

        let option_expiry_ms = 1000000;
        ueoption::initialize(admin, option_expiry_ms);

        let issuer_address = @0xA;
        let buyer_address = @0xB;
        let issuer = account::create_account_for_test(issuer_address);
        let buyer = account::create_account_for_test(buyer_address);
        coin::register<AptosCoin>(&issuer);
        coin::register<ueoption::UsdCoin>(&issuer);
        aptos_coin::mint(&aptos_framework, issuer_address, 2);
        coin::register<ueoption::UsdCoin>(&buyer);
        managed_coin::mint<ueoption::UsdCoin>(admin, buyer_address, 10);

        ueoption::underwrite(&issuer, b"APT", 1, 1, 1);

        ueoption::buy(&buyer, string::utf8(b"APT_USD-19700508-C-1U0000"), 1);

        let ra_address = ueoption::get_resource_account_address();
        let expected_new_option_address = token::create_token_address(
            &ra_address,
            &string::utf8(b"OTP"),
            &string::utf8(b"APT_USD-19700508-C-1U0000")
        );
        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            primary_fungible_store::balance(buyer_address, created_option_object) == 1,
            ETestExpectationFailure
        );
        assert!(
            fungible_asset::supply(created_option_object) == fungible_asset::maximum(created_option_object),
            ETestExpectationFailure // no remaining supply left
        );
        assert!(
            primary_fungible_store::balance(issuer_address, created_option_object) == 0,
            ETestExpectationFailure // issuer does not own his options
        );
        assert!(
            coin::balance<ueoption::UsdCoin>(buyer_address) == 9,
            ETestExpectationFailure // buyer initial balance 10 USD - option premium 1 USD = 9 USD
        );
        assert!(
            coin::balance<AptosCoin>(issuer_address) == 1,
            ETestExpectationFailure // issuer initial balance 2 APT - collaterized asset for 1 option 1 APT = 1 APT
        );
        assert!(
            coin::balance<ueoption::UsdCoin>(issuer_address) == 1,
            ETestExpectationFailure // 1 option + premium 1 USD = 1
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    fun test_buy_total_share_success(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let now = 1;
        timestamp::fast_forward_seconds(now);

        let option_expiry_ms = 2_000_000;
        ueoption::initialize(admin, option_expiry_ms);

        let issuer_address = @0xA;
        let buyer_address = @0xB;
        let issuer = account::create_account_for_test(issuer_address);
        let buyer = account::create_account_for_test(buyer_address);
        coin::register<AptosCoin>(&issuer);
        coin::register<ueoption::UsdCoin>(&issuer);
        aptos_coin::mint(&aptos_framework, issuer_address, 120);
        coin::register<ueoption::UsdCoin>(&buyer);
        managed_coin::mint<ueoption::UsdCoin>(admin, buyer_address, 10);

        ueoption::underwrite(&issuer, b"APT", 100, 10, 2);

        ueoption::buy(&buyer, string::utf8(b"APT_USD-19700204-C-1U0000"), 3);

        let ra_address = ueoption::get_resource_account_address();
        let expected_new_option_address = token::create_token_address(
            &ra_address,
            &string::utf8(b"OTP"),
            &string::utf8(b"APT_USD-19700204-C-1U0000")
        );
        let created_option_object = object::address_to_object<ProtocolOption>(expected_new_option_address);
        assert!(
            primary_fungible_store::balance(buyer_address, created_option_object) == 30,
            ETestExpectationFailure // supply 100 - multiplier 10 * amount 3 = 30
        );
        assert!(
            primary_fungible_store::balance(issuer_address, created_option_object) == 0,
            ETestExpectationFailure
        );
        assert!(
            fungible_asset::supply(created_option_object) == option::some(30),
            ETestExpectationFailure // minted supply
        );
        assert!(
            fungible_asset::maximum(created_option_object) == option::some(100),
            ETestExpectationFailure // maximum remains unchanged
        );
        assert!(
            coin::balance<ueoption::UsdCoin>(buyer_address) == 4,
            ETestExpectationFailure // owned - 3 option tokens (contracts) * 2 cost per contract = 4
        );
        assert!(
            coin::balance<AptosCoin>(issuer_address) == 20,
            ETestExpectationFailure // issuer intial balance 120 APT - 100 option * 1 APT  = 20 APT
            // ETestExpectationFailure // 3 option tokens (contracts) * 2 cost per contract = 6
        );
        assert!(
            coin::balance<ueoption::UsdCoin>(issuer_address) == 6,
            ETestExpectationFailure // 3 option tokens (option contracts) * 2 USD premium per contract = 26 APT
        );

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    // #[expected_failure(abort_code = 0x1F, location = otp::ueoption)]
    #[expected_failure(abort_code = 0x20005, location = aptos_framework::fungible_asset)]
    fun test_buy_over_supply_failure(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let now = 1;
        timestamp::fast_forward_seconds(now);

        let option_expiry_ms = 2_000_000;
        ueoption::initialize(admin, option_expiry_ms);

        let issuer_address = @0xA;
        let buyer_address = @0xB;
        let issuer = account::create_account_for_test(issuer_address);
        let buyer = account::create_account_for_test(buyer_address);
        coin::register<AptosCoin>(&issuer);
        coin::register<ueoption::UsdCoin>(&issuer);
        aptos_coin::mint(&aptos_framework, issuer_address, 120);
        coin::register<ueoption::UsdCoin>(&buyer);
        managed_coin::mint<ueoption::UsdCoin>(admin, buyer_address, 150);

        ueoption::underwrite(&issuer, b"APT", 100, 10, 2);

        ueoption::buy(&buyer, string::utf8(b"APT_USD-19700204-C-1U0000"), 11);

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test(admin = @admin_address)]
    #[expected_failure(abort_code = 0x10006, location = aptos_framework::coin)]
    fun test_buy_not_enough_funds_failure(admin: &signer) {
        let (aptos_framework, burn_cap, mint_cap) = setup_test_framework();

        let issuer_address = @0xA;
        let buyer_address = @0xB;
        let issuer = account::create_account_for_test(issuer_address);
        let buyer = account::create_account_for_test(buyer_address);
        coin::register<AptosCoin>(&issuer);
        coin::register<AptosCoin>(&buyer);
        aptos_coin::mint(&aptos_framework, buyer_address, 1);

        let now = 1;
        timestamp::fast_forward_seconds(now);

        let option_expiry_ms = 2_000_000;
        ueoption::initialize(admin, option_expiry_ms);
        ueoption::underwrite(&issuer, b"APT", 10, 1, 1);

        ueoption::buy(&buyer, string::utf8(b"APT:3000000"), 2);

        teardown_test_framework(burn_cap, mint_cap);
    }

    #[test()]
    fun test_get_asset_price_wbtc() {
        let (_aptos_framework, burn_cap, mint_cap) = setup_test_framework();

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
                        price_identifier::from_byte_vec(x"ea0459ab2954676022baaceadb472c1acc97888062864aa23e9771bae3ff36ed"),
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

        let btc_price = ueoption::get_asset_price(b"WBTC"); 
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
                        price_identifier::from_byte_vec(x"ea0459ab2954676022baaceadb472c1acc97888062864aa23e9771bae3ff36ed"),
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

        let btc_price = ueoption::get_asset_price(b"WBTC"); 
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
