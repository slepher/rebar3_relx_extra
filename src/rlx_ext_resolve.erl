%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 28 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_ext_resolve).

%% API
-export([solve_cluster/3]).

%%%===================================================================
%%% API
%%%===================================================================
solve_cluster(Cluster, Apps, State) ->
    
    ClusRelease = rlx_cluster:clus_release(Cluster),
    RelxState0 = rlx_ext_state:rlx_state(State),
    RelxState1 = rlx_state:available_apps(RelxState0, Apps),
    {ok, SolvedClusRelease, RelxState2} = rlx_resolve:solve_release(ClusRelease, RelxState1),
    Releases = rlx_cluster:releases(Cluster),
    SolvedRelease =
        lists:map(
          fun(Release) ->
                  {ok, SolvedRelease, _RelxState2} = rlx_resolve:solve_release(Release, RelxState2),
                  SolvedRelease
          end, Releases),
    Cluster1 = rlx_cluster:solved_clus_release(Cluster, SolvedClusRelease, SolvedRelease),
    State1 = rlx_ext_state:rlx_state(State, RelxState2),
    {ok, Cluster1, State1}.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
