examples:
- https://github.com/gmondok/ChainlinkCallOptions/blob/main/chainlinkOptions.sol

list of Aptos coins
- https://aptoscan.com/coins

## Roadmap

MVP

- [x] underwrite a CALL option with collateral
- [x] ability to buy a share
- [ ] scheduled option settlement at expiry
- [ ] underwrite a PUT option with collateral

## option symbol convention

Based on Options Clearing Corporation (OCC) Option Symbology Initiative (OSI) but taking into account the proposed format limits:

- OSI quote currency is implicitly USD, in cryptocurrency space we need to be open for the future where USDC, USDT, BTC can be quote currencies
- OSI max quote values for the option asset is 99999 in quote currency, that means BTC above 100k is not supported
- OSI year format is expressed with 2 numbers, which make it impossible to express options of year 2100 and beyond
- OSI base asset cannot be expressed with numbers

Proposed symbology

<TICKER, all uppercase>-YYYYMMDD-<C|P>-<#K###|###U####>

examples:
- BTC_USD-20220811-C-26K1000
- BTC_USD-20220811-P-25K3500
- BTC_USDC-20220811-P-25K3500
- BTC_RNBC-20220811-P-184K8000
- APT_USD-20220811-C-6U0000
- APT_USD-20220811-P-4U9000

For more info about OSI, search for "OPTIONS SYMBOLOGY INITIATIVE IMPLEMENTATION" by OCC at feb 3, 2010.

## unix timestamp to date conversion algo

- https://stackoverflow.com/a/32158604/6317812
- http://git.musl-libc.org/cgit/musl/tree/src/time/__secs_to_tm.c?h=v0.9.15
- https://opensource.apple.com/source/ntp/ntp-13/ntp/libntp/mktime.c

## useful move libraries

- https://github.com/pentagonxyz/movemate

## Glossary

VAA - Verifiable Action Approval, a proof that the message has been signed by the majority of the guardians (validators) of wormhole

DOV – DeFi options vault

Liquidity - efficiency or ease with which an asset or security can be converted into ready cash without affecting its market price

Liquidity (in crypto) - the ease or rapidity with which one can buy or sell a digital asset close to its market price

## Optimization ideas

- [x] do not mint option fungible token unit there is a buyer
- [ ] convert timestamp in the option name to date in format `08SEP2023`
- [ ] maybe it is better to use u128 for supply_amount for option tokens on creation
- [ ] freeze collaterized asset on the option issuer account instead of transfer it to resource account address
