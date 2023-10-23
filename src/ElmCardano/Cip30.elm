module ElmCardano.Cip30 exposing
    ( Request
    , Response(..)
    , Wallet
    , WalletDescriptor
    , discoverWallets
    , enableWallet
    , encodeRequest
    , getBalance
    , getChangeAddress
    , getCollateral
    , getExtensions
    , getNetworkId
    , getRewardAddresses
    , getUnusedAddresses
    , getUsedAddresses
    , getUtxos
    , responseDecoder
    , signData
    , walletDescriptor
    )

import Bytes exposing (Bytes)
import Cbor exposing (CborItem)
import Cbor.Decode
import Cbor.Encode
import ElmCardano.Transaction as Transaction
import Hex.Convert
import Json.Decode as JDecode exposing (Decoder, Value, maybe)
import Json.Encode as JEncode


type TODO
    = TODO


{-| The type returned when asking for available wallets.
-}
type alias WalletDescriptor =
    { id : String
    , name : String
    , icon : String
    , apiVersion : String
    , isEnabled : Bool
    , supportedExtensions : List Int
    }


type Wallet
    = Wallet
        { descriptor : WalletDescriptor
        , api : Value
        , walletHandle : Value
        }


walletDescriptor : Wallet -> WalletDescriptor
walletDescriptor (Wallet { descriptor }) =
    descriptor


type Request
    = DiscoverWallets
    | Enable { id : String, extensions : List Int }
    | ApiRequest
        { id : String
        , api : Value
        , method : String
        , args : List Value
        }


discoverWallets : Request
discoverWallets =
    DiscoverWallets


enableWallet : { id : String, extensions : List Int } -> Request
enableWallet idAndExtensions =
    Enable idAndExtensions


getExtensions : Wallet -> Request
getExtensions wallet =
    apiRequest wallet "getExtensions" []


getNetworkId : Wallet -> Request
getNetworkId wallet =
    apiRequest wallet "getNetworkId" []


getUtxos : Wallet -> { amount : Maybe Transaction.Value, paginate : Maybe Paginate } -> Request
getUtxos wallet { amount, paginate } =
    apiRequest wallet
        "getUtxos"
        [ encodeMaybe (\a -> Transaction.encodeValue a |> encodeCborHex) amount
        , encodeMaybe encodePaginate paginate
        ]


getCollateral : Wallet -> { amount : Transaction.Value } -> Request
getCollateral wallet { amount } =
    let
        params =
            JEncode.object [ ( "amount", Transaction.encodeValue amount |> encodeCborHex ) ]
    in
    apiRequest wallet "getCollateral" [ params ]


encodeCborHex : Cbor.Encode.Encoder -> Value
encodeCborHex cborEncoder =
    Cbor.Encode.encode cborEncoder
        |> Hex.Convert.toString
        |> JEncode.string


encodeMaybe : (a -> Value) -> Maybe a -> Value
encodeMaybe encode maybe =
    Maybe.map encode maybe
        |> Maybe.withDefault JEncode.null


getBalance : Wallet -> Request
getBalance wallet =
    apiRequest wallet "getBalance" []


getUsedAddresses : Wallet -> { paginate : Maybe Paginate } -> Request
getUsedAddresses wallet { paginate } =
    apiRequest wallet "getUsedAddresses" [ encodeMaybe encodePaginate paginate ]


getUnusedAddresses : Wallet -> Request
getUnusedAddresses wallet =
    apiRequest wallet "getUnusedAddresses" []


getChangeAddress : Wallet -> Request
getChangeAddress wallet =
    apiRequest wallet "getChangeAddress" []


getRewardAddresses : Wallet -> Request
getRewardAddresses wallet =
    apiRequest wallet "getRewardAddresses" []


signData : Wallet -> { addr : String, payload : Bytes } -> Request
signData wallet { addr, payload } =
    apiRequest wallet "signData" [ JEncode.string addr, JEncode.string <| Hex.Convert.toString payload ]



-- api.signTx(tx: cbor\, partialSign: bool = false)
-- api.submitTx(tx: cbor\)


type alias Paginate =
    { page : Int, limit : Int }


encodePaginate : Paginate -> Value
encodePaginate { page, limit } =
    JEncode.object [ ( "page", JEncode.int page ), ( "limit", JEncode.int limit ) ]


apiRequest : Wallet -> String -> List Value -> Request
apiRequest (Wallet { descriptor, api }) method args =
    ApiRequest
        { id = descriptor.id
        , api = api
        , method = method
        , args = args
        }


encodeRequest : Request -> Value
encodeRequest request =
    case request of
        DiscoverWallets ->
            JEncode.object
                [ ( "requestType", JEncode.string "cip30-discover" ) ]

        Enable { id, extensions } ->
            JEncode.object
                [ ( "requestType", JEncode.string "cip30-enable" )
                , ( "id", JEncode.string id )
                , ( "extensions", JEncode.list JEncode.int extensions )
                ]

        ApiRequest { id, api, method, args } ->
            JEncode.object
                [ ( "requestType", JEncode.string "cip30-api" )
                , ( "id", JEncode.string id )
                , ( "api", api )
                , ( "method", JEncode.string method )
                , ( "args", JEncode.list identity args )
                ]


type Response
    = AvailableWallets (List WalletDescriptor)
    | EnablingError { id : String } ApiError
    | EnabledWallet Wallet
    | Extensions { walletId : String, extensions : List Int }
    | NetworkId { walletId : String, networkId : Int }
      -- TODO: change utxos into Maybe (List Utxo)
    | WalletUtxos { walletId : String, utxos : Maybe (List Utxo) }
    | Collateral { walletId : String, collateral : Maybe (List Utxo) }
    | WalletBalance { walletId : String, balance : CborItem }
    | UsedAddresses { walletId : String, usedAddresses : List String }
    | UnusedAddresses { walletId : String, unusedAddresses : List String }
    | ChangeAddress { walletId : String, changeAddress : String }
    | RewardAddresses { walletId : String, rewardAddresses : List String }
    | SignedData { walletId : String, signedData : DataSignature }
    | UnhandledResponseType String


type alias Utxo =
    { outputReference : CborItem -- Transaction.Input
    , output : CborItem -- Transaction.Output
    }


type alias DataSignature =
    { signature : CborItem
    , key : CborItem
    }


type ApiError
    = ApiError String


responseDecoder : Decoder Response
responseDecoder =
    JDecode.field "responseType" JDecode.string
        |> JDecode.andThen
            (\responseType ->
                case responseType of
                    "cip30-discover" ->
                        discoverDecoder

                    "cip30-enable" ->
                        enableDecoder

                    "cip30-api" ->
                        JDecode.field "method" JDecode.string
                            |> JDecode.andThen
                                (\method ->
                                    JDecode.field "walletId" JDecode.string
                                        |> JDecode.andThen (apiDecoder method)
                                )

                    _ ->
                        JDecode.succeed (UnhandledResponseType responseType)
            )


discoverDecoder : Decoder Response
discoverDecoder =
    JDecode.list descriptorDecoder
        |> JDecode.field "wallets"
        |> JDecode.map AvailableWallets


descriptorDecoder : Decoder WalletDescriptor
descriptorDecoder =
    JDecode.map6
        -- Explicit constructor with names instead of using Cip30WalletDescriptor constructor
        (\id name icon apiVersion isEnabled supportedExtensions ->
            { id = id
            , name = name
            , icon = icon
            , apiVersion = apiVersion
            , isEnabled = isEnabled
            , supportedExtensions = supportedExtensions
            }
        )
        (JDecode.field "id" JDecode.string)
        (JDecode.field "name" JDecode.string)
        (JDecode.field "icon" JDecode.string)
        (JDecode.field "apiVersion" JDecode.string)
        (JDecode.field "isEnabled" JDecode.bool)
        (JDecode.field "supportedExtensions" (JDecode.list extensionDecoder))


enableDecoder : Decoder Response
enableDecoder =
    -- TODO: Handle the potential errors
    JDecode.map EnabledWallet <|
        JDecode.map3
            -- Explicit constructor to avoid messing with fields order
            (\descriptor api walletHandle ->
                Wallet
                    { descriptor = descriptor
                    , api = api
                    , walletHandle = walletHandle
                    }
            )
            (JDecode.field "descriptor" descriptorDecoder)
            (JDecode.field "api" JDecode.value)
            (JDecode.field "walletHandle" JDecode.value)


apiDecoder : String -> String -> Decoder Response
apiDecoder method walletId =
    case method of
        "getExtensions" ->
            JDecode.map (\r -> Extensions { walletId = walletId, extensions = r })
                (JDecode.field "response" <| JDecode.list extensionDecoder)

        "getNetworkId" ->
            JDecode.map (\n -> NetworkId { walletId = walletId, networkId = n })
                (JDecode.field "response" JDecode.int)

        "getUtxos" ->
            JDecode.list utxoDecoder
                |> JDecode.nullable
                |> JDecode.field "response"
                |> JDecode.map (\utxos -> WalletUtxos { walletId = walletId, utxos = utxos })

        "getCollateral" ->
            JDecode.list utxoDecoder
                |> JDecode.nullable
                |> JDecode.field "response"
                |> JDecode.map (\utxos -> Collateral { walletId = walletId, collateral = utxos })

        "getBalance" ->
            JDecode.map (\b -> WalletBalance { walletId = walletId, balance = b })
                (JDecode.field "response" <| hexCborDecoder Cbor.Decode.any)

        "getUsedAddresses" ->
            JDecode.map (\r -> UsedAddresses { walletId = walletId, usedAddresses = r })
                (JDecode.field "response" <| JDecode.list JDecode.string)

        "getUnusedAddresses" ->
            JDecode.map (\r -> UnusedAddresses { walletId = walletId, unusedAddresses = r })
                (JDecode.field "response" <| JDecode.list JDecode.string)

        "getChangeAddress" ->
            JDecode.map (\r -> ChangeAddress { walletId = walletId, changeAddress = r })
                (JDecode.field "response" JDecode.string)

        "getRewardAddresses" ->
            JDecode.map (\r -> RewardAddresses { walletId = walletId, rewardAddresses = r })
                (JDecode.field "response" <| JDecode.list JDecode.string)

        "signData" ->
            JDecode.map (\r -> SignedData { walletId = walletId, signedData = r })
                (JDecode.field "response" <| dataSignatureDecoder)

        _ ->
            JDecode.succeed <| UnhandledResponseType ("Unknown API call: " ++ method)


extensionDecoder : Decoder Int
extensionDecoder =
    JDecode.field "cip" JDecode.int


utxoDecoder : Decoder Utxo
utxoDecoder =
    hexCborDecoder <|
        Cbor.Decode.tuple Utxo <|
            Cbor.Decode.elems
                >> Cbor.Decode.elem Cbor.Decode.any
                >> Cbor.Decode.elem Cbor.Decode.any


dataSignatureDecoder : Decoder DataSignature
dataSignatureDecoder =
    JDecode.map2 DataSignature
        (JDecode.field "signature" <| hexCborDecoder Cbor.Decode.any)
        (JDecode.field "key" <| hexCborDecoder Cbor.Decode.any)


hexCborDecoder : Cbor.Decode.Decoder a -> Decoder a
hexCborDecoder decoder =
    JDecode.string
        |> JDecode.andThen
            (\str ->
                case Hex.Convert.toBytes str of
                    Just bytes ->
                        case Cbor.Decode.decode decoder bytes of
                            Just a ->
                                JDecode.succeed a

                            Nothing ->
                                JDecode.fail "Failed to decode CBOR"

                    Nothing ->
                        JDecode.fail "Invalid hex bytes"
            )
