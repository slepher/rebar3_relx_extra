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
    {ok, State2} = rebar3_prv_clusrel:init(State),
    {ok, State3} = rebar3_prv_clusup:init(State2),
    {ok, State4} = rebar3_prv_clustar:init(State3),
    {ok, State5} = rebar3_prv_clusuptar:init(State4),
    {ok, State6} = rebar3_prv_tar_ext:init(State5),
    {ok, State7} = rebar3_prv_gen_appup:init(State6),
    {ok, State7}.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
