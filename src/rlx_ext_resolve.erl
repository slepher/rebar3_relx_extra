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
    Config = rlx_cluster:config(Cluster),
    {ok, State1} = lists:foldl(fun rlx_ext_config:load/2, {ok, State}, Config),
    RelxState0 = rlx_ext_state:rlx_state(State1),
    RelxState1 = rlx_state:available_apps(RelxState0, Apps),
    
    {ok, SolvedClusRelease, RelxState2} = rlx_resolve:solve_release(ClusRelease, RelxState1),
    Releases = rlx_cluster:releases(Cluster),
    IncludeApps = rlx_ext_state:include_apps(State1),
    SolvedRelease =
        lists:map(
          fun(Release) ->
                  Goals = rlx_release:goals(Release),
                  Goals1 = merge_application_goals(IncludeApps, Goals),
                  Release1 = rlx_release:parsed_goals(Release, Goals1),
                  {ok, SolvedRelease, _RelxState2} = rlx_resolve:solve_release(Release1, RelxState2),
                  SolvedRelease
          end, Releases),
    Cluster1 = rlx_cluster:solved_clus_release(Cluster, SolvedClusRelease, SolvedRelease),
    State2 = rlx_ext_state:rlx_state(State1, RelxState2),
    {ok, Cluster1, State2}.

merge_application_goals(Goals, BaseGoals) ->
    lists:foldl(fun({Key, Goal}, Acc) ->
                        lists:keystore(Key, 1, Acc, {Key, Goal})
                end, BaseGoals, rlx_release:parse_goals(Goals)).


%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
