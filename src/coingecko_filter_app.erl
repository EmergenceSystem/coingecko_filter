%%%-------------------------------------------------------------------
%%% @doc CoinGecko crypto-search agent (api/v3/search, open, no key).
%%% Rate-limited (~10-30 req/min); a light per-query TTL cache in the
%%% agent Memory avoids hammering. Handler: handle/2 -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(coingecko_filter_app).
-export([handle/2, base_capabilities/0]).
-define(UA, "Mozilla/5.0 (X11; Linux aarch64; rv:128.0) Gecko/20100101 Firefox/128.0").
-define(TTL, 60).

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"crypto">>, <<"cryptocurrency">>, <<"bitcoin">>, <<"ethereum">>, <<"blockchain">>, <<"altcoin">>, <<"stablecoin">>, <<"defi">>].

handle(Body, Memory) when is_binary(Body) ->
    Q = extract_value(Body),
    Mem0 = case Memory of M when is_map(M) -> M; _ -> #{} end,
    Cache = maps:get(cache, Mem0, #{}),
    Now = erlang:system_time(second),
    case maps:get(Q, Cache, undefined) of
        {Ts, Res} when (Now - Ts) =< ?TTL ->
            {Res, Mem0};
        _ ->
            Res = gen(Q),
            {Res, Mem0#{cache => Cache#{Q => {Now, Res}}}}
    end;
handle(_Body, Memory) -> {[], Memory}.

gen("") -> [];
gen(Q) ->
    Url = "https://api.coingecko.com/api/v3/search?query=" ++ uri_string:quote(Q),
    case fetch_json(Url, 12) of
        {ok, #{<<"coins">> := Coins}} when is_list(Coins) ->
            [emb(C) || C <- Coins];
        _ -> []
    end.

emb(C) ->
    Id     = to_b(maps:get(<<"id">>, C, <<>>)),
    Name   = to_b(maps:get(<<"name">>, C, <<>>)),
    Symbol = to_b(maps:get(<<"symbol">>, C, <<>>)),
    Rank   = maps:get(<<"market_cap_rank">>, C, null),
    Url    = <<"https://www.coingecko.com/en/coins/", Id/binary>>,
    #{<<"properties">> => #{
        <<"url">>    => Url,
        <<"title">>  => Name,
        <<"resume">> => fmt("~ts~ts", [Symbol, rank_str(Rank)])}}.

rank_str(N) when is_integer(N) -> unicode:characters_to_binary(io_lib:format(" - rank #~p", [N]));
rank_str(_) -> <<>>.

extract_value(Body) ->
    try json:decode(Body) of
        M when is_map(M) ->
            binary_to_list(maps:get(<<"value">>, M, maps:get(<<"query">>, M, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

fetch_json(Url, T) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    case httpc:request(get, {Url, [{"User-Agent", ?UA}, {"Accept", "application/json"}]},
                       [{timeout, T * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, B}} -> try {ok, json:decode(B)} catch _:_ -> {error, badjson} end;
        {ok, {{_, C, _}, _, _}}   -> {error, {http, C}};
        {error, R}                -> {error, R}
    end.

to_b(B) when is_binary(B) -> B;
to_b(L) when is_list(L)   -> list_to_binary(L);
to_b(_)                   -> <<>>.
fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
