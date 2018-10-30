-module(rebar3_relx_extra).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, State1} = rebar3_relx_extra_prv:init(State),
    {ok, State1}.
