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
    {ok, State1} = rebar3_prv_release_ext:init(State),
    {ok, State2} = rebar3_prv_tar_ext:init(State1),
    {ok, State3} = rebar3_prv_clusup:init(State2),
    {ok, State3}.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
