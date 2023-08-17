module otp::ueoption {
    use std::signer;
    use std::timestamp;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};

    /**
     *  constants
     */
    const RA_SEED: vector<u8> = b"RA_UEOPTION";

    // Option states
    const OPTION_STATE_CANCELED: u8 = 0;
    const OPTION_STATE_INITIALIZED: u8 = 1;
    const OPTION_STATE_EXERCISED: u8 = 2;
    const OPTION_STATE_EXPIRED: u8 = 3;
    const DEFAULT_EXPIRY_MS: u64 = 604800000; // 7 days

    /**
     *  errors
     */
    const ENotAdmin: u64 = 0;

    /**
     *  structs
     */

    struct ProtocolOption has store, drop {
        strike: u64,
        premium: u64,
        // epoch timestamp in milliseconds
        expiry_ms: u64,
        state: u8,
        issuer_address: address,
        holder_address: address // FIXME: do i want to hold options in the PDA or move it to holders addresses?
    }

    // better name needed than State
    struct Repository has key {
        active: SimpleMap<u256, ProtocolOption>,
        signer_cap: SignerCapability
    }

    //=
    //= entry function
    //=

    public entry fun initialize(admin: &signer) {
        assert_admin(signer::address_of(admin));

        let (ra, signer_cap) = account::create_resource_account(admin, RA_SEED);
        move_to(
            &ra,
            Repository {
                active: simple_map::create(),
                signer_cap,
            }
        );
    }

    public entry fun underwrite(issuer: &signer) acquires Repository {
        let issuer_address = signer::address_of(issuer);
        let ra_address = get_resource_account_address();
        let repo = borrow_global_mut<Repository>(ra_address);
        let option = ProtocolOption {
            strike: 1,
            premium: 1,
            expiry_ms: timestamp::now_microseconds() + DEFAULT_EXPIRY_MS,
            state: OPTION_STATE_INITIALIZED,
            issuer_address,
            holder_address: issuer_address
        };
        simple_map::add(&mut repo.active, derive_option_id(&option), option);
        // FIXME: decide, should I move option to issuer?
    }
    // public entry fun list() {}
    // public entry fun buy() {}
    // public entry fun cancel() {}

    //=
    //= logic helper function
    //=

    // inline fun calculate_premium() {}

    inline fun derive_option_id(_option: &ProtocolOption): u256 {
        1
    }

    inline fun get_resource_account_address(): address {
        account::create_resource_address(&@admin_address, RA_SEED)
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

        initialize(admin);
        let expected_ra_addr = account::create_resource_address(&admin_address, RA_SEED);
        assert!(account::exists_at(expected_ra_addr), 0);
    }

    #[test(admin = @admin_address, issuer = @0xA)]
    fun test_underwrite_success(admin: &signer, issuer: &signer) acquires Repository {
        let admin_address = signer::address_of(admin);
        let aptos_framework = account::create_account_for_test(@aptos_framework);

        timestamp::set_time_has_started_for_testing(&aptos_framework);

        initialize(admin);

        let now = 10;
        timestamp::fast_forward_seconds(now);
        underwrite(issuer);

        let expected_ra_addr = account::create_resource_address(&admin_address, RA_SEED);
        let repo = borrow_global<Repository>(expected_ra_addr);

        let created_option = simple_map::borrow<u256, ProtocolOption>(&repo.active, &1);
        assert!(
            created_option.expiry_ms == now * 1000000 + DEFAULT_EXPIRY_MS,
            0
        );
    }
}
