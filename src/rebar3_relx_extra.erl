-module(rebar3_relx_extra).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, State1} = rebar3_prv_release_ext:init(State),
    {ok, State2} = rebar3_prv_tar_ext:init(State1),
    {ok, State2}.
