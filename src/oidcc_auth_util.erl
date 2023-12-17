%%%-------------------------------------------------------------------
%% @doc Authentication Utilities
%% @end
%%%-------------------------------------------------------------------
-module(oidcc_auth_util).

-feature(maybe_expr, enable).

-include("oidcc_client_context.hrl").
-include("oidcc_provider_configuration.hrl").

-include_lib("jose/include/jose_jwk.hrl").

-export_type([auth_method/0, error/0]).

-type auth_method() ::
    none | client_secret_basic | client_secret_post | client_secret_jwt | private_key_jwt.

-type error() :: no_supported_auth_method.

-export([add_client_authentication/6]).
-export([add_dpop_proof/4]).
-export([add_authorization_header/4]).

%% @private
-spec add_client_authentication(
    QueryList, Header, SupportedAuthMethods, AllowAlgorithms, Opts, ClientContext
) ->
    {ok, {oidcc_http_util:query_params(), [oidcc_http_util:http_header()]}}
    | {error, error()}
when
    QueryList :: oidcc_http_util:query_params(),
    Header :: [oidcc_http_util:http_header()],
    SupportedAuthMethods :: [binary()] | undefined,
    AllowAlgorithms :: [binary()] | undefined,
    Opts :: map(),
    ClientContext :: oidcc_client_context:t().
add_client_authentication(_QueryList, _Header, undefined, _AllowAlgs, _Opts, _ClientContext) ->
    {error, no_supported_auth_method};
add_client_authentication(
    QueryList0, Header0, SupportedAuthMethods, AllowAlgorithms, Opts, ClientContext
) ->
    PreferredAuthMethods = maps:get(preferred_auth_methods, Opts, [
        private_key_jwt,
        client_secret_jwt,
        client_secret_post,
        client_secret_basic,
        none
    ]),
    case select_preferred_auth(PreferredAuthMethods, SupportedAuthMethods) of
        {ok, AuthMethod} ->
            case
                add_authentication(
                    QueryList0, Header0, AuthMethod, AllowAlgorithms, Opts, ClientContext
                )
            of
                {ok, {QueryList, Header}} ->
                    {ok, {QueryList, Header}};
                {error, _} ->
                    add_client_authentication(
                        QueryList0,
                        Header0,
                        SupportedAuthMethods -- [atom_to_binary(AuthMethod)],
                        AllowAlgorithms,
                        Opts,
                        ClientContext
                    )
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec add_authentication(
    QueryList,
    Header,
    AuthMethod,
    AllowAlgorithms,
    Opts,
    ClientContext
) ->
    {ok, {oidcc_http_util:query_params(), [oidcc_http_util:http_header()]}}
    | {error, auth_method_not_possible}
when
    QueryList :: oidcc_http_util:query_params(),
    Header :: [oidcc_http_util:http_header()],
    AuthMethod :: auth_method(),
    AllowAlgorithms :: [binary()] | undefined,
    Opts :: map(),
    ClientContext :: oidcc_client_context:t().
add_authentication(
    QsBodyList,
    Header,
    none,
    _AllowArgs,
    _Opts,
    #oidcc_client_context{client_id = ClientId}
) ->
    NewBodyList = [{<<"client_id">>, ClientId} | QsBodyList],
    {ok, {NewBodyList, Header}};
add_authentication(
    _QsBodyList,
    _Header,
    _Method,
    _AllowAlgs,
    _Opts,
    #oidcc_client_context{client_secret = unauthenticated}
) ->
    {error, auth_method_not_possible};
add_authentication(
    QsBodyList,
    Header,
    client_secret_basic,
    _AllowAlgs,
    _Opts,
    #oidcc_client_context{client_id = ClientId, client_secret = ClientSecret}
) ->
    NewHeader = [oidcc_http_util:basic_auth_header(ClientId, ClientSecret) | Header],
    {ok, {QsBodyList, NewHeader}};
add_authentication(
    QsBodyList,
    Header,
    client_secret_post,
    _AllowAlgs,
    _Opts,
    #oidcc_client_context{client_id = ClientId, client_secret = ClientSecret}
) ->
    NewBodyList =
        [{<<"client_id">>, ClientId}, {<<"client_secret">>, ClientSecret} | QsBodyList],
    {ok, {NewBodyList, Header}};
add_authentication(
    QsBodyList,
    Header,
    client_secret_jwt,
    AllowAlgorithms,
    Opts,
    ClientContext
) ->
    #oidcc_client_context{
        client_secret = ClientSecret
    } = ClientContext,

    maybe
        [_ | _] ?= AllowAlgorithms,
        #jose_jwk{} =
            OctJwk ?=
                oidcc_jwt_util:client_secret_oct_keys(
                    AllowAlgorithms,
                    ClientSecret
                ),
        {ok, ClientAssertion} ?=
            signed_client_assertion(
                AllowAlgorithms,
                Opts,
                ClientContext,
                OctJwk
            ),
        {ok, add_jwt_bearer_assertion(ClientAssertion, QsBodyList, Header, ClientContext)}
    else
        _ ->
            {error, auth_method_not_possible}
    end;
add_authentication(
    QsBodyList0,
    Header,
    private_key_jwt,
    AllowAlgorithms,
    Opts,
    ClientContext
) ->
    #oidcc_client_context{
        client_jwks = ClientJwks
    } = ClientContext,

    maybe
        [_ | _] ?= AllowAlgorithms,
        #jose_jwk{} ?= ClientJwks,
        {ok, ClientAssertion} ?=
            signed_client_assertion(AllowAlgorithms, Opts, ClientContext, ClientJwks),
        QsBodyList = [{<<"dpop_jkt">>, jose_jwk:thumbprint(ClientJwks)} | QsBodyList0],
        {ok, add_jwt_bearer_assertion(ClientAssertion, QsBodyList, Header, ClientContext)}
    else
        _ ->
            {error, auth_method_not_possible}
    end.

-spec select_preferred_auth(PreferredAuthMethods, AuthMethodsSupported) ->
    {ok, auth_method()} | {error, error()}
when
    PreferredAuthMethods :: [auth_method(), ...],
    AuthMethodsSupported :: [binary()].
select_preferred_auth(PreferredAuthMethods, AuthMethodsSupported) ->
    PreferredAuthMethodSearchFun = fun(AuthMethod) ->
        lists:member(atom_to_binary(AuthMethod), AuthMethodsSupported)
    end,

    case lists:search(PreferredAuthMethodSearchFun, PreferredAuthMethods) of
        {value, AuthMethod} ->
            {ok, AuthMethod};
        false ->
            {error, no_supported_auth_method}
    end.

-spec signed_client_assertion(AllowAlgorithms, Opts, ClientContext, Jwk) ->
    {ok, binary()} | {error, term()}
when
    AllowAlgorithms :: [binary()],
    Jwk :: jose_jwk:key(),
    Opts :: map(),
    ClientContext :: oidcc_client_context:t().
signed_client_assertion(AllowAlgorithms, Opts, ClientContext, Jwk) ->
    Jwt = jose_jwt:from(token_request_claims(Opts, ClientContext)),

    oidcc_jwt_util:sign(Jwt, Jwk, AllowAlgorithms).

-spec token_request_claims(Opts, ClientContext) -> oidcc_jwt_util:claims() when
    Opts :: map(),
    ClientContext :: oidcc_client_context:t().
token_request_claims(Opts, #oidcc_client_context{
    client_id = ClientId,
    provider_configuration = #oidcc_provider_configuration{token_endpoint = TokenEndpoint}
}) ->
    Audience = maps:get(audience, Opts, TokenEndpoint),
    MaxClockSkew =
        case application:get_env(oidcc, max_clock_skew) of
            undefined -> 0;
            {ok, ClockSkew} -> ClockSkew
        end,

    #{
        <<"iss">> => ClientId,
        <<"sub">> => ClientId,
        <<"aud">> => Audience,
        <<"jti">> => random_string(32),
        <<"iat">> => os:system_time(seconds),
        <<"exp">> => os:system_time(seconds) + 30,
        <<"nbf">> => os:system_time(seconds) - MaxClockSkew
    }.

-spec add_jwt_bearer_assertion(ClientAssertion, Body, Header, ClientContext) -> {Body, Header} when
    ClientAssertion :: binary(),
    Body :: oidcc_http_util:query_params(),
    Header :: [oidcc_http_util:http_header()],
    ClientContext :: oidcc_client_context:t().
add_jwt_bearer_assertion(ClientAssertion, Body, Header, ClientContext) ->
    #oidcc_client_context{client_id = ClientId} = ClientContext,
    {
        [
            {<<"client_assertion_type">>,
                <<"urn:ietf:params:oauth:client-assertion-type:jwt-bearer">>},
            {<<"client_assertion">>, ClientAssertion},
            {<<"client_id">>, ClientId}
            | Body
        ],
        Header
    }.

%% @private
-spec add_dpop_proof(Header, Method, Endpoint, ClientContext) -> Header when
    Header :: [oidcc_http_util:http_header()],
    Method :: post | get,
    Endpoint :: uri_string:uri_string(),
    ClientContext :: oidcc_client_context:t().
add_dpop_proof(Header, Method, Endpoint, #oidcc_client_context{
    client_jwks = #jose_jwk{} = ClientJwks,
    provider_configuration = #oidcc_provider_configuration{
        dpop_signing_alg_values_supported = [_ | _] = SigningAlgSupported
    }
}) ->
    MaxClockSkew =
        case application:get_env(oidcc, max_clock_skew) of
            undefined -> 0;
            {ok, ClockSkew} -> ClockSkew
        end,
    HtmClaim =
        case Method of
            post -> <<"POST">>;
            get -> <<"GET">>
        end,
    Claims = #{
        <<"jti">> => random_string(32),
        <<"htm">> => HtmClaim,
        <<"htu">> => iolist_to_binary(Endpoint),
        <<"iat">> => os:system_time(seconds),
        <<"exp">> => os:system_time(seconds) + 30,
        <<"nbf">> => os:system_time(seconds) - MaxClockSkew
    },
    Jwt = jose_jwt:from(Claims),
    {_, PublicJwk} = jose_jwk:to_public_map(ClientJwks),
    case
        oidcc_jwt_util:sign(Jwt, ClientJwks, SigningAlgSupported, #{
            <<"typ">> => <<"dpop+jwt">>, <<"jwk">> => PublicJwk
        })
    of
        {ok, SignedRequestObject} ->
            [{"dpop", SignedRequestObject} | Header];
        {error, no_supported_alg_or_key} ->
            Header
    end;
add_dpop_proof(Header, _Method, _Endpoint, _ClientContext) ->
    Header.

%% @private
-spec add_authorization_header(AccessToken, Method, Endpoint, ClientContext) -> Header when
    AccessToken :: binary(),
    Method :: post | get,
    Endpoint :: uri_string:uri_string(),
    ClientContext :: oidcc_client_context:t(),
    Header :: [oidcc_http_util:http_header()].
add_authorization_header(AccessToken, Method, Endpoint, #oidcc_client_context{
    client_jwks = #jose_jwk{} = ClientJwks,
    provider_configuration = #oidcc_provider_configuration{
        dpop_signing_alg_values_supported = [_ | _] = SigningAlgSupported
    }
}) when is_binary(AccessToken) ->
    MaxClockSkew =
        case application:get_env(oidcc, max_clock_skew) of
            undefined -> 0;
            {ok, ClockSkew} -> ClockSkew
        end,
    HtmClaim =
        case Method of
            post -> <<"POST">>;
            get -> <<"GET">>
        end,
    Claims = #{
        <<"jti">> => random_string(32),
        <<"htm">> => HtmClaim,
        <<"htu">> => iolist_to_binary(Endpoint),
        <<"iat">> => os:system_time(seconds),
        <<"exp">> => os:system_time(seconds) + 30,
        <<"nbf">> => os:system_time(seconds) - MaxClockSkew,
        <<"ath">> => base64:encode(crypto:hash(sha256, AccessToken), #{
            mode => urlsafe, padding => false
        })
    },
    Jwt = jose_jwt:from(Claims),
    {_, PublicJwk} = jose_jwk:to_public_map(ClientJwks),
    case
        oidcc_jwt_util:sign(Jwt, ClientJwks, SigningAlgSupported, #{
            <<"typ">> => <<"dpop+jwt">>, <<"jwk">> => PublicJwk
        })
    of
        {ok, SignedRequestObject} ->
            [
                {"authorization", [<<"DPoP ">>, AccessToken]},
                {"dpop", SignedRequestObject}
            ];
        {error, no_supported_alg_or_key} ->
            [oidcc_http_util:bearer_auth_header(AccessToken)]
    end;
add_authorization_header(AccessToken, _Method, _Endpoint, _ClientContext) when
    is_binary(AccessToken)
->
    [oidcc_http_util:bearer_auth_header(AccessToken)].

-spec random_string(Bytes :: pos_integer()) -> binary().
random_string(Bytes) ->
    base64:encode(crypto:strong_rand_bytes(Bytes), #{mode => urlsafe, padding => false}).
