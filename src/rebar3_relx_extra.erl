%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2019, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 17 Dec 2019 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rebar3_relx_extra).

%% API
-export([init/1]).

%%%===================================================================
%%% API
%%%===================================================================


-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    %% {ok, State1} = rebar3_prv_release_ext:init(State),
    {ok, State1} = rebar_prv_gen_appup:init(State),
    {ok, State2} = rebar_prv_clusrel:init(State1),
    {ok, State3} = rebar_prv_clusup:init(State2),
    {ok, State4} = rebar_prv_clustar:init(State3),
    {ok, State5} = rebar_prv_clusuptar:init(State4),
    {ok, State5}.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
